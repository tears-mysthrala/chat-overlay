defmodule ChatOverlay.AdaptersTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.{Adapters, KickWebhook}

  test "Twitch message and deletion use different identifiers, whitelist and verify channel" do
    source = %{"platform" => "twitch", "channel" => "123"}

    data = %{
      "metadata" => %{
        "message_id" => "event1",
        "message_timestamp" => "2026-09-20T12:00:00Z",
        "subscription_type" => "channel.chat.message"
      },
      "payload" => %{
        "event" => %{
          "broadcaster_user_id" => "123",
          "message_id" => "message1",
          "chatter_user_id" => "456",
          "chatter_user_name" => "Alice",
          "message" => %{"text" => "Hi"},
          "token" => "must-not-leak"
        }
      }
    }

    assert {:ok, event} = Adapters.twitch(data, source)
    assert event["upstream_id"] == "event1"
    assert event["payload"]["message_id"] == "message1"
    refute inspect(event) =~ "must-not-leak"
    assert {:error, :wrong_channel} = Adapters.twitch(data, %{source | "channel" => "private"})

    assert {:ok, %{"event" => "delete_message"}} =
             Adapters.twitch(
               put_in(data, ["metadata", "subscription_type"], "channel.chat.message_delete"),
               source
             )

    assert :ignore =
             Adapters.twitch(
               put_in(data, ["metadata", "subscription_type"], "future.event"),
               source
             )
  end

  test "YouTube deleted messages and banned authors retain session scope" do
    source = %{"platform" => "youtube", "channel" => "channel", "live_chat_id" => "session"}

    data = %{
      "id" => "del1",
      "snippet" => %{
        "liveChatId" => "session",
        "type" => "messageDeletedEvent",
        "publishedAt" => "2026-09-20T12:00:00Z",
        "messageDeletedDetails" => %{"deletedMessageId" => "msg"}
      }
    }

    assert {:ok, %{"emission_session" => "session", "payload" => %{"message_id" => "msg"}}} =
             Adapters.youtube(data, source)

    assert {:error, :wrong_channel} =
             Adapters.youtube(put_in(data, ["snippet", "liveChatId"], "private"), source)
  end

  test "Kick signed notifications reject forgery, tampering and old timestamps" do
    private = :public_key.generate_key({:rsa, 2048, 65537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    now = ~U[2026-09-20 12:00:00Z]

    body =
      ~s({"broadcaster":{"user_id":123},"sender":{"user_id":456,"username":"Alice"},"message_id":"m1","content":"Hi","created_at":"2026-09-20T11:59:00Z"})

    id = "event1"
    timestamp = DateTime.to_iso8601(now)

    signature =
      :public_key.sign(id <> "." <> timestamp <> "." <> body, :sha256, private) |> Base.encode64()

    headers = %{
      "kick-event-message-id" => id,
      "kick-event-message-timestamp" => timestamp,
      "kick-event-signature" => signature
    }

    assert KickWebhook.verify(headers, body, public, now)
    refute KickWebhook.verify(headers, body <> " ", public, now)
    refute KickWebhook.verify(headers, body, public, DateTime.add(now, 301))

    refute KickWebhook.verify(
             Map.put(headers, "kick-event-signature", "invalid"),
             body,
             public,
             now
           )

    refute KickWebhook.verify(
             Map.put(headers, "kick-event-message-id", "other"),
             body,
             public,
             now
           )

    assert {:ok, event} = ChatOverlay.JSON.decode(body)

    assert {:ok, %{"payload" => %{"author_id" => "456"}}} =
             Adapters.kick("chat.message.sent", id, timestamp, event, %{
               "platform" => "kick",
               "channel" => "123"
             })

    assert {:error, :wrong_channel} =
             Adapters.kick("chat.message.sent", id, timestamp, event, %{
               "platform" => "kick",
               "channel" => "789"
             })
  end

  test "Kick ordering uses payload occurrence time, not signed delivery time" do
    source = %{"platform" => "kick", "channel" => "123"}

    message = %{
      "broadcaster" => %{"user_id" => 123},
      "sender" => %{"user_id" => 456, "username" => "Alice"},
      "message_id" => "before-ban",
      "content" => "text",
      "created_at" => "2026-09-20T12:00:00Z"
    }

    ban = %{
      "broadcaster" => %{"user_id" => 123},
      "banned_user" => %{"user_id" => 456},
      "metadata" => %{"created_at" => "2026-09-20T12:01:00Z"}
    }

    {:ok, deletion} =
      Adapters.kick("moderation.banned", "ban", "2026-09-20T12:02:00Z", ban, source)

    {:ok, delayed} =
      Adapters.kick("chat.message.sent", "msg", "2026-09-20T12:03:00Z", message, source)

    assert deletion["occurred_at"] == "2026-09-20T12:01:00Z"
    assert delayed["occurred_at"] == "2026-09-20T12:00:00Z"

    store =
      start_supervised!(%{
        id: :kick_store,
        start: {ChatOverlay.Store, :start_link, [[sources: [source]]]}
      })

    assert :ok = ChatOverlay.Store.ingest(store, deletion)
    assert {:error, :deleted} = ChatOverlay.Store.ingest(store, delayed)

    assert {:error, :invalid_event} =
             Adapters.kick(
               "chat.message.sent",
               "bad",
               "2026-09-20T12:03:00Z",
               Map.delete(message, "created_at"),
               source
             )
  end
end
