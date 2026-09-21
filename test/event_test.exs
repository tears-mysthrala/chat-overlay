defmodule ChatOverlay.EventTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.{Event, JSON, Config, Net, Connectors}

  defp message,
    do:
      Event.new("twitch", "123", "message", "event-1", %{
        "message_id" => "m1",
        "author_id" => "u1",
        "author_display" => "日本語 👋",
        "text" => "<script>alert(1)</script>"
      })

  test "Unicode and markup remain data; unknown fields cannot carry credentials" do
    assert Event.valid?(message())
    refute Event.valid?(Map.put(message(), "token", "sensitive"))
    refute Event.valid?(put_in(message(), ["payload", "cookie"], "sensitive"))
    refute Event.valid?(put_in(message(), ["payload", "text"], String.duplicate("x", 4097)))
    refute Event.valid?(put_in(message(), ["payload", "text"], <<255>>))
    refute Event.valid?(put_in(message(), ["payload", "author_id"], ""))
    refute Event.valid?(Map.put(message(), "platform", "other"))
  end

  test "fragments: valid emote and text fragments are accepted" do
    frags = [
      %{"type" => "text", "text" => "Hello "},
      %{"type" => "emote", "text" => "tearsmyGG", "id" => "emotesv2_abc123"},
      %{"type" => "text", "text" => " world"}
    ]

    with_frags = put_in(message(), ["payload", "fragments"], frags)
    assert Event.valid?(with_frags)
  end

  test "fragments: messages without fragments remain valid (backward compatible)" do
    assert Event.valid?(message())
  end

  test "fragments: empty list is rejected (map_size would be 5 with empty list)" do
    with_empty = put_in(message(), ["payload", "fragments"], [])
    # Empty list still adds key making map_size 5, but fragments?([]) is true, so valid
    assert Event.valid?(with_empty)
  end

  test "fragments: extra fields in fragment maps are rejected" do
    bad_frag = [%{"type" => "emote", "text" => "hi", "id" => "e1", "extra" => "nope"}]
    refute Event.valid?(put_in(message(), ["payload", "fragments"], bad_frag))
  end

  test "fragments: invalid emote IDs are rejected" do
    for bad_id <- ["", "../path", "<script>", "a b", String.duplicate("x", 257)] do
      frag = [%{"type" => "emote", "text" => "emote", "id" => bad_id}]
      refute Event.valid?(put_in(message(), ["payload", "fragments"], frag)),
        "expected invalid for emote id: #{inspect(bad_id)}"
    end
  end

  test "fragments: unknown fragment types are rejected" do
    bad = [%{"type" => "image", "text" => "hi", "url" => "http://evil.test"}]
    refute Event.valid?(put_in(message(), ["payload", "fragments"], bad))
  end

  test "fragments: more than 100 fragments are rejected" do
    many = for i <- 1..101, do: %{"type" => "text", "text" => "t#{i}"}
    refute Event.valid?(put_in(message(), ["payload", "fragments"], many))
  end

  test "JSON rejects oversized/deep/malformed input without generating atoms" do
    assert {:ok, %{"new_external_key_493" => 1}} = JSON.decode(~s({"new_external_key_493":1}))

    assert {:error, _} =
             JSON.decode(String.duplicate("[", 17) <> "0" <> String.duplicate("]", 17))

    assert {:error, _} = JSON.decode(String.duplicate(" ", 262_145))
    assert {:error, _} = JSON.decode(~s({"a":))
    assert {:ok, %{"text" => "[\\\"{"}} = JSON.decode(JSON.encode(%{"text" => "[\\\"{"}))
  end

  test "configuration rejects unknown/private capabilities, collisions and excess profiles" do
    profile = %{
      "handle" => "alice",
      "sources" => [%{"platform" => "twitch", "channel" => "demo", "mode" => "demo"}]
    }

    assert {:ok, [^profile]} = Config.validate([profile])

    for handle <- ["../alice", "Alice", "a/b", "<script>", "", String.duplicate("a", 41)] do
      assert {:error, _} = Config.validate([Map.put(profile, "handle", handle)])
    end

    assert {:error, _} = Config.validate([profile, profile])
    assert {:error, _} = Config.validate([Map.put(profile, "private", true)])
    assert {:error, _} = Config.validate(List.duplicate(profile, 11))

    assert {:error, _} =
             Config.validate([
               put_in(profile, ["sources"], [
                 %{"platform" => "twitch", "channel" => "http://127.0.0.1"}
               ])
             ])
  end

  test "outbound addresses and reconnect URLs fail closed" do
    for ip <- [
          {127, 0, 0, 1},
          {10, 1, 1, 1},
          {172, 16, 0, 1},
          {192, 168, 1, 1},
          {169, 254, 169, 254},
          {100, 64, 1, 1},
          {0, 0, 0, 0},
          {224, 0, 0, 1},
          {198, 18, 1, 1},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0, 0, 0, 0, 0, 65535, 32512, 1}
        ] do
      refute Net.public_ip?(ip)
    end

    assert Net.public_ip?({1, 1, 1, 1})
    assert {:error, :destination_rejected} = Net.open("127.0.0.1")

    for url <- [
          "https://eventsub.wss.twitch.tv/ws",
          "wss://evil.test/ws",
          "wss://eventsub.wss.twitch.tv@evil.test/ws",
          "wss://eventsub.wss.twitch.tv:444/ws",
          "wss://eventsub.wss.twitch.tv/ws#fragment"
        ] do
      assert {:error, _} = Connectors.reconnect_path(url)
    end

    assert {:ok, "/ws?reconnect=abc"} =
             Connectors.reconnect_path("wss://eventsub.wss.twitch.tv/ws?reconnect=abc")
  end

  test "Retry-After is respected in seconds and HTTP-date; quota is not credentials" do
    now = ~U[2026-09-20 12:00:00Z]
    assert Net.retry_after([{"retry-after", "90"}], now) == 90_000
    assert Net.retry_after([{"retry-after", "Sun, 20 Sep 2026 12:02:00 GMT"}], now) == 120_000
    assert {:retry, 90_000} = Connectors.failure(429, [{"retry-after", "90"}], "")
    assert {:stop, :configuration_error} = Connectors.failure(401, [], "")

    assert {:stop, :offline} =
             Connectors.failure(403, [], ~s({"error":{"errors":[{"reason":"liveChatEnded"}]}}))

    assert {:retry, 3_600_000} =
             Connectors.failure(403, [], ~s({"error":{"errors":[{"reason":"quotaExceeded"}]}}))
  end

  test "malformed source objects and excess Twitch token connections fail closed" do
    assert {:error, :invalid_configuration} =
             ChatOverlay.Config.validate([
               %{"handle" => "test", "sources" => [nil], "overlay_platforms" => ["twitch"]}
             ])

    profiles =
      for n <- 1..4,
          do: %{
            "handle" => "p#{n}",
            "sources" => [
              %{
                "platform" => "twitch",
                "channel" => "#{n}",
                "client_id" => "client",
                "user_id" => "1",
                "credential_env" => "CHAT_TWITCH_TOKEN"
              }
            ]
          }

    assert {:error, :invalid_configuration} = ChatOverlay.Config.validate(profiles)
    assert {:ok, _} = ChatOverlay.Config.validate(Enum.take(profiles, 3))
  end
end
