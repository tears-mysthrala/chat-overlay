defmodule ChatOverlay.Connectors do
  @moduledoc "Read-only official connectors. Workers own sockets and all waits."
  alias ChatOverlay.{Adapters, Event, JSON, Net, Source}

  defp request(host, method, path, headers, body \\ "") do
    # Trusted application configuration is injectable for offline protocol tests.
    Application.get_env(:chat_overlay, :request_module, Net).request(
      host,
      method,
      path,
      headers,
      body
    )
  end

  @twitch_events ~w(channel.chat.message channel.chat.message_delete channel.chat.clear_user_messages channel.chat.clear)
  def run(%{"platform" => "youtube"} = s), do: youtube(s, nil)

  def run(%{"platform" => "twitch"} = s) do
    with {:ok, token} <- Net.token(s),
         :ok <- validate_twitch(s, token),
         {:ok, socket} <- ChatOverlay.Socket.open("/ws?keepalive_timeout_seconds=30") do
      try do
        twitch_loop(
          s,
          token,
          socket,
          30_000,
          false,
          nil,
          System.monotonic_time(:millisecond),
          System.monotonic_time(:millisecond) + 30_000
        )
      after
        ChatOverlay.Socket.close(socket)
      end
    else
      {:error, :configuration_error} -> {:stop, :configuration_error}
      {:retry, _} = retry -> retry
      _ -> {:retry, 5000}
    end
  end

  def run(%{"platform" => "kick"} = s), do: kick_health(s)

  def demo(s, n \\ 0) do
    Source.status(s, "available")

    texts = [
      "Bienvenidos al directo 👋",
      "Se lee perfecto desde aquí.",
      "日本語 también funciona",
      "Texto seguro: <img src=x onerror=alert(1)>",
      "Tres chats, una conversación."
    ]

    e =
      Event.new(
        s["platform"],
        s["channel"],
        "message",
        "demo-#{System.unique_integer([:positive])}",
        %{
          "message_id" => "demo-#{n}",
          "author_id" => "demo-#{rem(n, 4)}",
          "author_display" => Enum.at(["Luna", "Kai", "Nerea", "Álex"], rem(n, 4)),
          "text" => Enum.at(texts, rem(n, length(texts)))
        },
        occurred_at: DateTime.to_iso8601(DateTime.utc_now())
      )

    Source.publish(s, e)
    Process.sleep(2500 + :rand.uniform(1500))
    demo(s, n + 1)
  end

  defp youtube(s, page) do
    with {:ok, token} <- Net.token(s) do
      query = %{
        "liveChatId" => s["live_chat_id"],
        "part" => "id,snippet,authorDetails",
        "maxResults" => "200",
        "fields" =>
          "items(id,snippet(liveChatId,type,publishedAt,displayMessage,messageDeletedDetails/deletedMessageId,userBannedDetails/bannedUserDetails/channelId),authorDetails(channelId,displayName)),nextPageToken,pollingIntervalMillis,offlineAt"
      }

      query = if page, do: Map.put(query, "pageToken", page), else: query

      case request(
             "www.googleapis.com",
             "GET",
             "/youtube/v3/liveChat/messages?" <> URI.encode_query(query),
             [{"authorization", "Bearer " <> token}]
           ) do
        {:ok, 200, _, raw} ->
          with {:ok,
                %{"items" => items, "pollingIntervalMillis" => wait, "nextPageToken" => next} =
                  body} <- JSON.decode(raw, Net.body_limit("www.googleapis.com")),
               true <-
                 is_list(items) and length(items) <= 200 and is_integer(wait) and
                   wait in 1..3_600_000 and Event.text?(next, 4096),
               true <- Enum.all?(items, &deliver(Adapters.youtube(&1, s), s)) do
            if body["offlineAt"] do
              {:stop, :offline}
            else
              Source.status(s, "available")
              Source.defer(s, max(wait, 1000))
              Process.sleep(max(wait, 1000))
              youtube(s, next)
            end
          else
            _ -> {:retry, 60_000}
          end

        {:ok, status, headers, raw} ->
          failure(status, headers, raw)

        _ ->
          {:retry, 5000}
      end
    else
      _ -> {:stop, :configuration_error}
    end
  end

  def failure(status, headers, raw) do
    reason =
      case JSON.decode(raw) do
        {:ok, %{"error" => %{"errors" => [%{"reason" => reason} | _]}}} -> reason
        _ -> nil
      end

    cond do
      reason in ["liveChatEnded", "liveChatDisabled", "liveChatNotFound"] ->
        {:stop, :offline}

      reason in ["quotaExceeded", "dailyLimitExceeded"] ->
        {:retry, max(3_600_000, Net.retry_after(headers))}

      status == 429 or reason == "rateLimitExceeded" ->
        {:retry, Net.retry_after(headers)}

      status in [401, 403, 404] ->
        {:stop, :configuration_error}

      true ->
        delay =
          if List.keymember?(headers, "retry-after", 0),
            do: max(5000, Net.retry_after(headers)),
            else: 5000

        {:retry, delay}
    end
  end

  defp validate_twitch(s, token) do
    case request("id.twitch.tv", "GET", "/oauth2/validate", [
           {"authorization", "OAuth " <> token}
         ]) do
      {:ok, 200, _, raw} ->
        with {:ok, data} <- JSON.decode(raw),
             true <- data["client_id"] == s["client_id"] and data["user_id"] == s["user_id"],
             scopes when is_list(scopes) <- data["scopes"],
             true <- "user:read:chat" in scopes do
          :ok
        else
          _ -> {:error, :configuration_error}
        end

      {:ok, status, _, _} when status in [401, 403] ->
        {:error, :configuration_error}

      {:ok, status, headers, raw} ->
        failure(status, headers, raw)

      _ ->
        {:error, :upstream_unavailable}
    end
  end

  defp twitch_loop(s, token, socket, timeout, ready, previous, validated, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:retry, 5000}
    else
      case ChatOverlay.Socket.recv(socket, remaining) do
        {:ok, {:ping, bytes}, socket} ->
          case ChatOverlay.Socket.pong(socket, bytes) do
            {:ok, socket} ->
              twitch_loop(s, token, socket, timeout, ready, previous, validated, deadline)

            _ ->
              {:retry, 5000}
          end

        {:ok, {:text, raw}, socket} ->
          case JSON.decode(raw) do
            {:ok,
             %{
               "metadata" => %{"message_type" => "session_welcome"},
               "payload" => %{"session" => session}
             }} ->
              with true <- Event.id?(session["id"]),
                   seconds when is_integer(seconds) and seconds in 10..600 <-
                     session["keepalive_timeout_seconds"],
                   :ok <-
                     if(previous,
                       do: drain_old(s, previous, 128),
                       else: subscribe(s, token, session["id"])
                     ) do
                if previous, do: ChatOverlay.Socket.close(previous)
                next_timeout = seconds * 1000 + 1000

                twitch_loop(
                  s,
                  token,
                  socket,
                  next_timeout,
                  true,
                  nil,
                  validated,
                  System.monotonic_time(:millisecond) + next_timeout
                )
              else
                {:retry, _} = retry -> retry
                _ -> {:stop, :configuration_error}
              end

            {:ok, %{"metadata" => %{"message_type" => kind}} = data}
            when kind in ["notification", "session_keepalive"] and ready ->
              valid =
                if kind == "notification", do: deliver(Adapters.twitch(data, s), s), else: true

              revalidate = System.monotonic_time(:millisecond) - validated >= 3_600_000
              validation = if revalidate, do: validate_twitch(s, token), else: :ok

              if valid and validation == :ok do
                Source.status(s, "available")

                next_validated =
                  if revalidate, do: System.monotonic_time(:millisecond), else: validated

                twitch_loop(
                  s,
                  token,
                  socket,
                  timeout,
                  ready,
                  previous,
                  next_validated,
                  System.monotonic_time(:millisecond) + timeout
                )
              else
                case validation do
                  {:error, :configuration_error} -> {:stop, :configuration_error}
                  {:retry, _} = retry -> retry
                  _ -> {:retry, 5000}
                end
              end

            {:ok,
             %{
               "metadata" => %{"message_type" => "session_reconnect"},
               "payload" => %{"session" => %{"reconnect_url" => url}}
             }} ->
              with {:ok, path} <- reconnect_path(url),
                   {:ok, next} <- ChatOverlay.Socket.open(path) do
                try do
                  twitch_loop(
                    s,
                    token,
                    next,
                    timeout,
                    false,
                    socket,
                    validated,
                    System.monotonic_time(:millisecond) + timeout
                  )
                after
                  ChatOverlay.Socket.close(next)
                end
              else
                _ -> {:retry, 5000}
              end

            {:ok, %{"metadata" => %{"message_type" => "revocation"}}} ->
              {:stop, :configuration_error}

            _ ->
              {:retry, 5000}
          end

        _ ->
          {:retry, 5000}
      end
    end
  end

  defp drain_old(_, _, 0), do: {:retry, 1000}

  defp drain_old(s, socket, left) do
    case ChatOverlay.Socket.recv(socket, 1) do
      {:ok, {:text, raw}, socket} ->
        case JSON.decode(raw) do
          {:ok, %{"metadata" => %{"message_type" => "notification"}} = event} ->
            if deliver(Adapters.twitch(event, s), s),
              do: drain_old(s, socket, left - 1),
              else: {:retry, 1000}

          {:ok, %{"metadata" => %{"message_type" => "session_keepalive"}}} ->
            drain_old(s, socket, left - 1)

          {:ok, %{"metadata" => %{"message_type" => "revocation"}}} ->
            {:stop, :configuration_error}

          _ ->
            {:retry, 1000}
        end

      {:ok, {:ping, bytes}, socket} ->
        case ChatOverlay.Socket.pong(socket, bytes) do
          {:ok, socket} -> drain_old(s, socket, left - 1)
          _ -> {:retry, 1000}
        end

      {:error, :timeout} ->
        :ok

      # Lost/partial notifications may include deletions: restart through Source's clear barrier.
      _ ->
        {:retry, 1000}
    end
  end

  def reconnect_path(url) when is_binary(url) and byte_size(url) <= 2048 do
    uri = URI.parse(url)

    if uri.scheme == "wss" and uri.host == "eventsub.wss.twitch.tv" and uri.port == 443 and
         is_nil(uri.userinfo) and is_nil(uri.fragment) do
      {:ok, (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")}
    else
      {:error, :destination_rejected}
    end
  end

  def reconnect_path(_), do: {:error, :destination_rejected}

  defp subscribe(s, token, session) do
    Enum.reduce_while(@twitch_events, :ok, fn type, _ ->
      body =
        JSON.encode(%{
          "type" => type,
          "version" => "1",
          "condition" => %{"broadcaster_user_id" => s["channel"], "user_id" => s["user_id"]},
          "transport" => %{"method" => "websocket", "session_id" => session}
        })

      case request(
             "api.twitch.tv",
             "POST",
             "/helix/eventsub/subscriptions",
             [
               {"authorization", "Bearer " <> token},
               {"client-id", s["client_id"]},
               {"content-type", "application/json"}
             ],
             body
           ) do
        {:ok, 202, _, _} -> {:cont, :ok}
        {:ok, status, headers, raw} -> {:halt, failure(status, headers, raw)}
        _ -> {:halt, {:retry, 5000}}
      end
    end)
  end

  defp kick_health(s) do
    with {:ok, token} <- Net.token(s) do
      case request("api.kick.com", "GET", "/public/v1/events/subscriptions", [
             {"authorization", "Bearer " <> token}
           ]) do
        {:ok, 200, _, body} ->
          with {:ok, %{"data" => data}} when is_list(data) <- JSON.decode(body),
               true <-
                 Enum.any?(
                   data,
                   &(&1["id"] == s["subscription_id"] and
                       to_string(&1["broadcaster_user_id"]) == s["channel"])
                 ),
               true <-
                 is_nil(s["moderation_subscription_id"]) or
                   Enum.any?(
                     data,
                     &(&1["id"] == s["moderation_subscription_id"] and
                         to_string(&1["broadcaster_user_id"]) == s["channel"])
                   ) do
            # Subscription exists, but delivery has no heartbeat. Do not claim freshness.
            Source.status(s, "degraded")
            Process.sleep(60_000)
            kick_health(s)
          else
            _ -> {:stop, :configuration_error}
          end

        {:ok, status, headers, body} ->
          failure(status, headers, body)

        _ ->
          {:retry, 5000}
      end
    else
      _ -> {:stop, :configuration_error}
    end
  end

  defp deliver({:ok, event}, source), do: Source.publish(source, event)
  defp deliver(:ignore, _), do: true
  defp deliver(_, _), do: false
end
