defmodule ChatOverlay.Resolver do
  @moduledoc "Dynamic platform channel and live stream resolver."
  alias ChatOverlay.{JSON, Net}

  def validate_twitch_token(token) when is_binary(token) and byte_size(token) > 0 do
    case Net.request("id.twitch.tv", "GET", "/oauth2/validate", [
           {"authorization", "Bearer " <> token}
         ]) do
      {:ok, 200, _, raw} ->
        with {:ok, data} <- JSON.decode(raw) do
          {:ok,
           %{
             "client_id" => data["client_id"],
             "user_id" => data["user_id"],
             "login" => data["login"],
             "scopes" => data["scopes"] || []
           }}
        else
          _ -> {:error, :invalid_response}
        end

      {:ok, status, _, _} ->
        {:error, {:invalid_token, status}}

      _ ->
        {:error, :upstream_unavailable}
    end
  end

  def validate_twitch_token(_), do: {:error, :invalid_token}

  def resolve_twitch(input, opts \\ []) do
    token = opts[:token] || System.get_env("CHAT_TWITCH_TOKEN") || ""
    client_id = opts[:client_id] || System.get_env("CHAT_TWITCH_CLIENT_ID")
    user_id = opts[:user_id] || System.get_env("CHAT_TWITCH_USER_ID")

    with {:ok, slug} <- clean_twitch_slug(input),
         true <- byte_size(token) > 0,
         {:ok, {client_id, user_id}} <- introspect_twitch_creds(token, client_id, user_id),
         true <-
           is_binary(client_id) and byte_size(client_id) > 0 and
             is_binary(user_id) and byte_size(user_id) > 0 do
      query =
        if Regex.match?(~r/\A[0-9]+\z/, slug),
          do: "/helix/users?id=" <> URI.encode(slug),
          else: "/helix/users?login=" <> URI.encode(slug)

      case Net.request(
             "api.twitch.tv",
             "GET",
             query,
             [
               {"authorization", "Bearer " <> token},
               {"client-id", client_id}
             ]
           ) do
        {:ok, 200, _, raw} ->
          with {:ok, %{"data" => [user | _]}} <- JSON.decode(raw) do
            {:ok,
             %{
               "channel" => user["id"],
               "login" => user["login"],
               "display_name" => user["display_name"],
               "client_id" => client_id,
               "user_id" => user_id
             }}
          else
            _ -> {:error, :user_not_found}
          end

        {:ok, status, _, _} ->
          {:error, {:twitch_api_error, status}}

        _ ->
          {:error, :upstream_unavailable}
      end
    else
      false -> {:error, :missing_twitch_credentials}
      error -> error
    end
  end

  defp introspect_twitch_creds(token, client_id, user_id) do
    if is_nil(client_id) or is_nil(user_id) or client_id == "" or user_id == "" do
      case validate_twitch_token(token) do
        {:ok, auth} ->
          {:ok, {client_id || auth["client_id"], user_id || auth["user_id"]}}

        error ->
          error
      end
    else
      {:ok, {client_id, user_id}}
    end
  end

  def resolve_youtube(input, opts \\ []) do
    token = opts[:token] || System.get_env("CHAT_YOUTUBE_TOKEN") || ""

    with {:ok, target} <- clean_youtube_target(input),
         true <- byte_size(token) > 0 do
      headers = [youtube_auth_header(token)]

      case target do
        {:video, video_id} ->
          resolve_youtube_video(video_id, headers)

        {:handle, handle} ->
          with {:ok, channel_id} <- resolve_youtube_handle(handle, headers) do
            resolve_youtube_live_stream(channel_id, headers, handle)
          end

        {:channel, channel_id} ->
          resolve_youtube_live_stream(channel_id, headers, nil)
      end
    else
      false -> {:error, :missing_youtube_credentials}
      error -> error
    end
  end

  defp resolve_youtube_video(video_id, headers, handle \\ nil) do
    path =
      "/youtube/v3/videos?" <>
        URI.encode_query(%{
          "id" => video_id,
          "part" => "snippet,liveStreamingDetails"
        })

    case Net.request("www.googleapis.com", "GET", path, headers) do
      {:ok, 200, _, raw} ->
        with {:ok, %{"items" => [item | _]}} <-
               JSON.decode(raw, Net.body_limit("www.googleapis.com")),
             chat_id when is_binary(chat_id) <-
               get_in(item, ["liveStreamingDetails", "activeLiveChatId"]) do
          {:ok,
           %{
             "channel" => item["snippet"]["channelId"],
             "live_chat_id" => chat_id,
             "title" => item["snippet"]["title"],
             "handle" => handle
           }}
        else
          _ -> {:error, :no_active_live_chat}
        end

      {:ok, status, _, _} ->
        {:error, {:youtube_api_error, status}}

      _ ->
        {:error, :upstream_unavailable}
    end
  end

  defp resolve_youtube_handle(handle, headers) do
    path =
      "/youtube/v3/channels?" <>
        URI.encode_query(%{
          "forHandle" => handle,
          "part" => "id,snippet"
        })

    case Net.request("www.googleapis.com", "GET", path, headers) do
      {:ok, 200, _, raw} ->
        with {:ok, %{"items" => [item | _]}} <-
               JSON.decode(raw, Net.body_limit("www.googleapis.com")),
             channel_id when is_binary(channel_id) <- item["id"] do
          {:ok, channel_id}
        else
          _ -> {:error, :channel_not_found}
        end

      {:ok, status, _, _} ->
        {:error, {:youtube_api_error, status}}

      _ ->
        {:error, :upstream_unavailable}
    end
  end

  defp resolve_youtube_live_stream(channel_id, headers, handle) do
    path =
      "/youtube/v3/search?" <>
        URI.encode_query(%{
          "channelId" => channel_id,
          "eventType" => "live",
          "type" => "video",
          "part" => "id,snippet"
        })

    case Net.request("www.googleapis.com", "GET", path, headers) do
      {:ok, 200, _, raw} ->
        with {:ok, %{"items" => [item | _]}} <-
               JSON.decode(raw, Net.body_limit("www.googleapis.com")),
             video_id when is_binary(video_id) <- item["id"]["videoId"] do
          resolve_youtube_video(video_id, headers, handle)
        else
          _ -> {:error, :no_active_stream}
        end

      {:ok, status, _, _} ->
        {:error, {:youtube_api_error, status}}

      _ ->
        {:error, :upstream_unavailable}
    end
  end

  def clean_twitch_slug(input) when is_binary(input) do
    trimmed = input |> String.trim() |> ensure_scheme()

    slug =
      cond do
        String.starts_with?(trimmed, ["http://", "https://"]) ->
          uri = URI.parse(trimmed)
          host = String.downcase(uri.host || "")

          if host in ["twitch.tv", "www.twitch.tv", "m.twitch.tv"] do
            parts = String.split(uri.path || "", "/", trim: true)

            case parts do
              ["popout", channel, "chat" | _] -> channel
              [channel | _] -> channel
              _ -> ""
            end
          else
            ""
          end

        String.starts_with?(trimmed, "@") ->
          String.trim_leading(trimmed, "@")

        true ->
          trimmed
      end
      |> String.downcase()

    if Regex.match?(~r/\A[a-z0-9_]{1,40}\z/, slug) do
      {:ok, slug}
    else
      {:error, :invalid_twitch_channel}
    end
  end

  def clean_twitch_slug(_), do: {:error, :invalid_twitch_channel}

  def clean_youtube_target(input) when is_binary(input) do
    trimmed = input |> String.trim() |> ensure_scheme()

    cond do
      String.starts_with?(trimmed, ["http://", "https://"]) ->
        uri = URI.parse(trimmed)
        query = URI.decode_query(uri.query || "")

        cond do
          query["v"] && Regex.match?(~r/\A[a-zA-Z0-9_\-]{11}\z/, query["v"]) ->
            {:ok, {:video, query["v"]}}

          Regex.match?(~r/\A\/live\/([a-zA-Z0-9_\-]{11})\/?\z/, uri.path || "") ->
            [_, video_id] = Regex.run(~r/\A\/live\/([a-zA-Z0-9_\-]{11})\/?\z/, uri.path)
            {:ok, {:video, video_id}}

          String.contains?(uri.host || "", "youtu.be") and
              Regex.match?(~r/\A\/[a-zA-Z0-9_\-]{11}\z/, uri.path || "") ->
            {:ok, {:video, String.trim_leading(uri.path, "/")}}

          String.starts_with?(uri.path || "", "/@") ->
            handle = uri.path |> String.split("/", trim: true) |> hd() |> String.trim_leading("@")
            validate_youtube_handle(handle)

          String.starts_with?(uri.path || "", "/channel/") ->
            channel = uri.path |> String.split("/", trim: true) |> List.last()
            validate_youtube_channel(channel)

          true ->
            {:error, :invalid_youtube_target}
        end

      String.starts_with?(trimmed, "@") ->
        validate_youtube_handle(String.trim_leading(trimmed, "@"))

      String.starts_with?(trimmed, "UC") and byte_size(trimmed) == 24 ->
        validate_youtube_channel(trimmed)

      Regex.match?(~r/\A[a-zA-Z0-9_\-]{11}\z/, trimmed) ->
        {:ok, {:video, trimmed}}

      true ->
        validate_youtube_handle(trimmed)
    end
  end

  def clean_youtube_target(_), do: {:error, :invalid_youtube_target}

  defp ensure_scheme(input) do
    if not String.starts_with?(input, ["http://", "https://"]) and
         String.starts_with?(input, [
           "twitch.tv/",
           "www.twitch.tv/",
           "youtube.com/",
           "www.youtube.com/",
           "youtu.be/"
         ]) do
      "https://" <> input
    else
      input
    end
  end

  defp validate_youtube_handle(handle) do
    if Regex.match?(~r/\A[a-zA-Z0-9_\-\.]{1,60}\z/, handle),
      do: {:ok, {:handle, handle}},
      else: {:error, :invalid_youtube_handle}
  end

  defp validate_youtube_channel(channel) do
    if Regex.match?(~r/\AUC[a-zA-Z0-9_\-]{22}\z/, channel),
      do: {:ok, {:channel, channel}},
      else: {:error, :invalid_youtube_channel}
  end

  defp youtube_auth_header(token) do
    if String.starts_with?(token, "AIza"),
      do: {"x-goog-api-key", token},
      else: {"authorization", "Bearer " <> token}
  end
end
