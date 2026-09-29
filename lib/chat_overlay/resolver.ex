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
               "description" => user["description"] || "",
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

  @doc "Discovers a linked YouTube channel URL from Twitch channel social links or description."
  def discover_twitch_youtube(login, opts \\ [])

  def discover_twitch_youtube(login, opts) when is_binary(login) do
    clean_login = String.downcase(String.trim(login))

    case discover_from_gql(clean_login) do
      {:ok, yt_url} ->
        {:ok, yt_url}

      _ ->
        desc =
          case opts[:description] do
            d when is_binary(d) ->
              d

            _ ->
              case resolve_twitch(clean_login, opts) do
                {:ok, %{"description" => d}} when is_binary(d) -> d
                _ -> ""
              end
          end

        discover_from_description(desc)
    end
  end

  def discover_twitch_youtube(_, _), do: {:error, :invalid_login}

  defp discover_from_gql(slug) do
    if System.get_env("CHAT_DISABLE_TWITCH_GQL") in ["1", "true"] do
      {:error, :disabled}
    else
      {query_str, variables} =
        if Regex.match?(~r/\A[0-9]+\z/, slug) do
          {"query($id: ID) { user(id: $id) { description channel { socialMedias { name title url } } } }",
           %{"id" => slug}}
        else
          {"query($login: String) { user(login: $login) { description channel { socialMedias { name title url } } } }",
           %{"login" => slug}}
        end

      query = %{
        "query" => query_str,
        "variables" => variables
      }

      case Net.request(
             "gql.twitch.tv",
             "POST",
             "/gql",
             [
               {"client-id", "kimne78kx3ncx6brgo4mv6wki5h1ko"},
               {"content-type", "application/json"}
             ],
             JSON.encode(query)
           ) do
        {:ok, 200, _, raw} ->
          with {:ok, data} <- JSON.decode(raw),
               user when is_map(user) <- get_in(data, ["data", "user"]) do
            medias = get_in(user, ["channel", "socialMedias"]) || []

            yt_link =
              Enum.find_value(medias, fn item ->
                name = String.downcase(item["name"] || "")
                url = item["url"] || ""
                lower_url = String.downcase(url)

                if name == "youtube" or String.contains?(lower_url, ["youtube.com", "youtu.be"]) do
                  url
                end
              end)

            cond do
              is_binary(yt_link) and byte_size(yt_link) > 0 ->
                {:ok, yt_link}

              is_binary(user["description"]) and byte_size(user["description"]) > 0 ->
                discover_from_description(user["description"])

              true ->
                {:error, :no_youtube_link}
            end
          else
            _ -> {:error, :no_youtube_link}
          end

        _ ->
          {:error, :no_youtube_link}
      end
    end
  end

  defp discover_from_description(description) when is_binary(description) do
    case Regex.run(
           ~r/https?:\/\/(?:www\.)?(?:youtube\.com\/(?:@[a-zA-Z0-9_\-\.]+|channel\/[a-zA-Z0-9_\-]+|c\/[a-zA-Z0-9_\-\.]+|user\/[a-zA-Z0-9_\-\.]+|watch\?[^\s"'>]+|live\/[a-zA-Z0-9_\-]+)|youtu\.be\/[a-zA-Z0-9_\-]+)/,
           description
         ) do
      [url | _] -> {:ok, url}
      _ -> {:error, :no_youtube_link}
    end
  end

  defp discover_from_description(_), do: {:error, :no_youtube_link}

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
          case resolve_youtube_video(video_id, headers) do
            {:ok, info} ->
              {:ok, info}

            {:error, {:no_active_live_chat, channel_id}} ->
              case resolve_youtube_live_stream(channel_id, headers, nil) do
                {:ok, live_info} ->
                  {:ok, live_info}

                {:error, :no_active_stream} ->
                  {:error, {:no_active_stream, "https://www.youtube.com/channel/" <> channel_id}}

                error ->
                  error
              end

            {:error, :no_active_live_chat} ->
              {:error, :no_active_stream}

            error ->
              error
          end

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
               JSON.decode(raw, Net.body_limit("www.googleapis.com")) do
          chat_id = get_in(item, ["liveStreamingDetails", "activeLiveChatId"])

          if is_binary(chat_id) and byte_size(chat_id) > 0 do
            {:ok,
             %{
               "channel" => item["snippet"]["channelId"],
               "live_chat_id" => chat_id,
               "title" => item["snippet"]["title"],
               "handle" => handle
             }}
          else
            channel_id = get_in(item, ["snippet", "channelId"])

            if is_binary(channel_id) and byte_size(channel_id) > 0 do
              {:error, {:no_active_live_chat, channel_id}}
            else
              {:error, :no_active_live_chat}
            end
          end
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
    params_to_try = [{"forHandle", handle}, {"forUsername", handle}]

    Enum.find_value(params_to_try, {:error, :channel_not_found}, fn {param, val} ->
      path =
        "/youtube/v3/channels?" <>
          URI.encode_query(%{
            param => val,
            "part" => "id,snippet"
          })

      case Net.request("www.googleapis.com", "GET", path, headers) do
        {:ok, 200, _, raw} ->
          with {:ok, %{"items" => [item | _]}} <-
                 JSON.decode(raw, Net.body_limit("www.googleapis.com")),
               channel_id when is_binary(channel_id) <- item["id"] do
            {:ok, channel_id}
          else
            _ -> nil
          end

        {:ok, status, _, _} ->
          {:error, {:youtube_api_error, status}}

        _ ->
          nil
      end
    end)
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

          String.starts_with?(uri.path || "", ["/c/", "/user/"]) ->
            handle =
              uri.path
              |> String.split("/", trim: true)
              |> List.last()
              |> String.trim_leading("@")

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
