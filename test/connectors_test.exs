defmodule ChatOverlay.ScriptedHTTP do
  def request(host, method, path, headers, body) do
    send(self(), {:requested, host, method, path, headers, body})
    [response | rest] = Process.get(:http_responses)
    Process.put(:http_responses, rest)
    response
  end
end

defmodule ChatOverlay.ConnectorsTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Connectors, JSON}

  setup do
    Application.put_env(:chat_overlay, :request_module, ChatOverlay.ScriptedHTTP)
    System.put_env("CHAT_TEST_PROTOCOL", "synthetic-token")

    on_exit(fn ->
      Application.delete_env(:chat_overlay, :request_module)
      System.delete_env("CHAT_TEST_PROTOCOL")
    end)

    %{
      source: %{
        "platform" => "youtube",
        "channel" => "other-channel",
        "live_chat_id" => "chat-id",
        "credential_env" => "CHAT_TEST_PROTOCOL"
      }
    }
  end

  test "YouTube resumes with continuation and respects poll interval without credentials in URLs",
       %{source: source} do
    response = %{"items" => [], "pollingIntervalMillis" => 1000, "nextPageToken" => "page+/=1"}

    Process.put(:http_responses, [
      {:ok, 200, [], JSON.encode(response)},
      {:ok, 403, [], ~s({"error":{"errors":[{"reason":"liveChatEnded"}]}})}
    ])

    start = System.monotonic_time(:millisecond)
    assert {:stop, :offline} = Connectors.run(source)
    assert System.monotonic_time(:millisecond) - start >= 1000
    assert_received {:requested, "www.googleapis.com", "GET", first, headers, ""}
    refute first =~ "pageToken"
    refute first =~ "synthetic-token"
    assert {"authorization", "Bearer synthetic-token"} in headers
    assert_received {:requested, "www.googleapis.com", "GET", second, _, ""}
    assert URI.decode_query(URI.parse(second).query)["pageToken"] == "page+/=1"
  end

  test "upstream oversized/malformed responses degrade instead of spinning", %{source: source} do
    Process.put(:http_responses, [{:ok, 200, [], "{broken"}])
    assert {:retry, 60_000} = Connectors.run(source)
    assert [] = Process.get(:http_responses)
  end

  test "missing credentials make no network request", %{source: source} do
    System.delete_env("CHAT_TEST_PROTOCOL")
    assert {:stop, :configuration_error} = Connectors.run(source)
    refute_received {:requested, _, _, _, _, _}
  end

  test "Twitch validates token identity before opening a websocket" do
    Process.put(:http_responses, [
      {:ok, 200, [],
       JSON.encode(%{"client_id" => "wrong", "user_id" => "999", "scopes" => ["user:read:chat"]})}
    ])

    source = %{
      "platform" => "twitch",
      "channel" => "123",
      "user_id" => "456",
      "client_id" => "correct",
      "credential_env" => "CHAT_TEST_PROTOCOL"
    }

    assert {:stop, :configuration_error} = Connectors.run(source)
    assert_received {:requested, "id.twitch.tv", "GET", "/oauth2/validate", _, _}
  end

  test "a missing Kick subscription is a configuration failure" do
    Process.put(:http_responses, [{:ok, 200, [], ~s({"data":[]})}])

    source = %{
      "platform" => "kick",
      "channel" => "123",
      "subscription_id" => "s1",
      "credential_env" => "CHAT_TEST_PROTOCOL"
    }

    assert {:stop, :configuration_error} = Connectors.run(source)
    assert_received {:requested, "api.kick.com", "GET", "/public/v1/events/subscriptions", _, _}
  end

  test "YouTube accepts a full bounded Unicode page with selected fields", %{source: source} do
    items =
      for n <- 1..200,
          do: %{
            "id" => "message-#{n}",
            "snippet" => %{
              "type" => "textMessageEvent",
              "liveChatId" => "chat-id",
              "publishedAt" => "2026-09-20T12:00:00Z",
              "displayMessage" => String.duplicate("界", 1300)
            },
            "authorDetails" => %{"channelId" => "author", "displayName" => "Nombre"}
          }

    raw =
      JSON.encode(%{
        "items" => items,
        "pollingIntervalMillis" => 1000,
        "nextPageToken" => "next",
        "offlineAt" => "2026-09-20T12:01:00Z"
      })

    assert byte_size(raw) > 262_144
    Process.put(:http_responses, [{:ok, 200, [], raw}])
    assert {:stop, :offline} = Connectors.run(source)
    assert_received {:requested, _, _, path, _, _}
    assert URI.decode_query(URI.parse(path).query)["fields"] =~ "messageDeletedDetails"
    assert {:error, :too_large} = JSON.decode(String.duplicate("x", 2_097_153), 2_097_152)
  end

  test "server Retry-After applies to platform reads and Twitch validation" do
    assert {:retry, 120_000} = Connectors.failure(503, [{"retry-after", "120"}], "")
    Process.put(:http_responses, [{:ok, 503, [{"retry-after", "120"}], ""}])

    source = %{
      "platform" => "twitch",
      "channel" => "123",
      "user_id" => "456",
      "client_id" => "client",
      "credential_env" => "CHAT_TEST_PROTOCOL"
    }

    assert {:retry, 120_000} = Connectors.run(source)
  end
end
