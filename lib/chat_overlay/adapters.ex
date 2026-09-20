defmodule ChatOverlay.Adapters do
  @moduledoc "Pure parsers. Whitelist fields; never expose upstream objects."
  alias ChatOverlay.Event

  def twitch(%{"metadata" => meta, "payload" => %{"event" => event}}, source)
      when is_map(meta) and is_map(event) do
    if event["broadcaster_user_id"] == source["channel"] do
      parsed =
        case meta["subscription_type"] do
          "channel.chat.message" ->
            {"message",
             message(
               event["message_id"],
               event["chatter_user_id"],
               event["chatter_user_name"],
               get_in(event, ["message", "text"])
             )}

          "channel.chat.message_delete" ->
            {"delete_message", %{"message_id" => event["message_id"]}}

          "channel.chat.clear_user_messages" ->
            {"delete_author", %{"author_id" => event["target_user_id"]}}

          "channel.chat.clear" ->
            {"clear_channel", %{"scope" => "channel"}}

          _ ->
            :ignore
        end

      build(source, parsed, meta["message_id"], meta["message_timestamp"])
    else
      {:error, :wrong_channel}
    end
  end

  def twitch(_, _), do: {:error, :invalid_event}

  def youtube(%{"id" => id, "snippet" => s} = event, source) when is_map(s) do
    if s["liveChatId"] == source["live_chat_id"] do
      author = event["authorDetails"] || %{}

      parsed =
        case s["type"] do
          type
          when type in [
                 "textMessageEvent",
                 "superChatEvent",
                 "superStickerEvent",
                 "newSponsorEvent",
                 "memberMilestoneChatEvent"
               ] ->
            {"message",
             message(id, author["channelId"], author["displayName"], s["displayMessage"] || "")}

          "messageDeletedEvent" ->
            {"delete_message",
             %{"message_id" => get_in(s, ["messageDeletedDetails", "deletedMessageId"])}}

          "userBannedEvent" ->
            {"delete_author",
             %{"author_id" => get_in(s, ["userBannedDetails", "bannedUserDetails", "channelId"])}}

          "chatEndedEvent" ->
            {"source_state", %{"state" => "offline", "observed_at" => s["publishedAt"]}}

          _ ->
            :ignore
        end

      build(source, parsed, id, s["publishedAt"])
    else
      {:error, :wrong_channel}
    end
  end

  def youtube(_, _), do: {:error, :invalid_event}

  def kick(
        type,
        id,
        _delivery_timestamp,
        %{"broadcaster" => %{"user_id" => channel}} = event,
        source
      ) do
    if to_string(channel) == source["channel"] do
      parsed =
        case type do
          "chat.message.sent" ->
            sender = event["sender"] || %{}

            {"message",
             message(
               event["message_id"],
               scalar_id(sender["user_id"]),
               sender["username"],
               event["content"]
             )}

          "moderation.banned" ->
            {"delete_author",
             %{"author_id" => scalar_id(get_in(event, ["banned_user", "user_id"]))}}

          _ ->
            :ignore
        end

      at =
        case type do
          "chat.message.sent" -> event["created_at"]
          "moderation.banned" -> get_in(event, ["metadata", "created_at"])
          _ -> nil
        end

      if parsed == :ignore or Event.timestamp?(at),
        do: build(source, parsed, id, at),
        else: {:error, :invalid_event}
    else
      {:error, :wrong_channel}
    end
  end

  def kick(_, _, _, _, _), do: {:error, :invalid_event}
  defp scalar_id(x) when is_integer(x) and x > 0, do: Integer.to_string(x)
  defp scalar_id(_), do: nil

  defp message(id, author, display, text),
    do: %{"message_id" => id, "author_id" => author, "author_display" => display, "text" => text}

  defp build(_, :ignore, _, _), do: :ignore

  defp build(source, {type, payload}, id, at) do
    event =
      Event.new(source["platform"], source["channel"], type, id, payload,
        occurred_at: at,
        session: source["live_chat_id"]
      )

    if Event.valid?(event), do: {:ok, event}, else: {:error, :invalid_event}
  end
end
