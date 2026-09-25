defmodule ChatOverlay.Adapters do
  @moduledoc "Pure parsers. Whitelist fields; never expose upstream objects."
  alias ChatOverlay.Event

  def twitch(%{"metadata" => meta, "payload" => %{"event" => event}}, source)
      when is_map(meta) and is_map(event) do
    if event["broadcaster_user_id"] == source["channel"] do
      parsed =
        case meta["subscription_type"] do
          "channel.chat.message" ->
            frags = parse_twitch_fragments(event["message"])

            {"message",
             message(
               event["message_id"],
               event["chatter_user_id"],
               event["chatter_user_name"],
               get_in(event, ["message", "text"]),
               frags
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

  defp message(id, author, display, text, fragments \\ nil)

  defp message(id, author, display, text, nil),
    do: %{"message_id" => id, "author_id" => author, "author_display" => display, "text" => text}

  defp message(id, author, display, text, []),
    do: message(id, author, display, text, nil)

  defp message(id, author, display, text, fragments) when is_list(fragments),
    do: %{
      "message_id" => id,
      "author_id" => author,
      "author_display" => display,
      "text" => text,
      "fragments" => fragments
    }

  defp parse_twitch_fragments(%{"fragments" => frags})
       when is_list(frags) and length(frags) > 0 and length(frags) <= 100 do
    parsed =
      Enum.map(frags, fn
        %{"type" => "emote", "text" => text, "emote" => %{"id" => id}}
        when is_binary(text) and is_binary(id) ->
          cond do
            valid_emote_id?(id) and Event.text?(text, 256) ->
              %{"type" => "emote", "text" => text, "id" => id}

            Event.text?(text, 4096) ->
              %{"type" => "text", "text" => text}

            true ->
              nil
          end

        %{"text" => text} when is_binary(text) ->
          if Event.text?(text, 4096), do: %{"type" => "text", "text" => text}, else: nil

        _ ->
          nil
      end)

    total_bytes =
      Enum.reduce(parsed, 0, fn f, acc ->
        acc + if is_map(f), do: byte_size(f["text"] || ""), else: 0
      end)

    if Enum.any?(parsed, &is_nil/1) or total_bytes > 4096, do: nil, else: parsed
  end

  defp parse_twitch_fragments(_), do: nil

  # Mirrors ChatOverlay.Event emote rules so one bad emote degrades to text
  # instead of failing validation and dropping the whole message.
  defp valid_emote_id?(id),
    do: byte_size(id) > 0 and byte_size(id) <= 256 and Regex.match?(~r/\A[a-zA-Z0-9_\-:]+\z/, id)

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
