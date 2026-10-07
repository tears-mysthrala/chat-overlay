defmodule ChatOverlay.Custodian.Result do
  @moduledoc "Closed response envelope; platform credentials cannot cross into the public role."
  @raw_media_limit 2_097_152
  @base64_limit 4 * div(@raw_media_limit + 2, 3)
  @limit ChatOverlay.JSON.custodian_response_limit()

  def max_bytes, do: @limit

  def decode(bytes) do
    with {:ok, result} <- ChatOverlay.JSON.decode(bytes, @limit),
         :ok <- validate(result) do
      {:ok, result}
    else
      _ -> {:error, :response_rejected}
    end
  end

  def validate(result) do
    if shape?(result) and byte_size(ChatOverlay.JSON.encode(result)) <= @limit,
      do: :ok,
      else: {:error, :response_rejected}
  end

  defp shape?(
         %{
           "version" => 1,
           "kind" => "json",
           "status" => status,
           "data" => data,
           "cookies" => cookies
         } = result
       )
       when map_size(result) == 5,
       do: status in 200..599 and is_map(data) and public_json?(data) and cookies?(cookies)

  defp shape?(
         %{
           "version" => 1,
           "kind" => "redirect",
           "status" => status,
           "location" => location,
           "cookies" => cookies
         } = result
       )
       when map_size(result) == 5,
       do: status in [301, 302, 303] and location?(location) and cookies?(cookies)

  defp shape?(%{"version" => 1, "kind" => "readiness", "ready" => ready} = result)
       when map_size(result) == 3, do: is_boolean(ready)

  defp shape?(%{"version" => 1, "kind" => "view", "status" => status, "demo" => demo} = result)
       when map_size(result) == 4, do: status in [200, 401, 403, 404] and is_boolean(demo)

  defp shape?(%{"version" => 1, "kind" => "upload_permit", "size" => size} = result)
       when map_size(result) == 3, do: is_integer(size) and size in 1..2_097_152

  defp shape?(%{"version" => 1, "kind" => "media", "status" => 404} = result)
       when map_size(result) == 3, do: true

  defp shape?(
         %{
           "version" => 1,
           "kind" => "media",
           "status" => 200,
           "mime" => mime,
           "size" => size,
           "sha256" => hash,
           "bytes" => bytes
         } = result
       )
       when map_size(result) == 7 do
    with true <- mime in ["image/png", "audio/wav"],
         true <- is_integer(size) and size in 1..2_097_152,
         true <- is_binary(bytes) and byte_size(bytes) <= @base64_limit,
         {:ok, decoded} <- Base.decode64(bytes),
         true <- byte_size(decoded) == size,
         true <- Base.encode16(:crypto.hash(:sha256, decoded), case: :lower) == hash do
      true
    else
      _ -> false
    end
  end

  defp shape?(_), do: false

  defp location?(location) when is_binary(location) and byte_size(location) <= 16_384 do
    if String.valid?(location) and not String.contains?(location, ["\r", "\n", <<0>>, "\\"]) do
      case URI.parse(location) do
        %URI{scheme: nil, host: nil, path: "/", fragment: nil} ->
          true

        %URI{scheme: "https", host: host, port: 443, userinfo: nil, fragment: nil, path: path} ->
          {host, path} in [
            {"id.twitch.tv", "/oauth2/authorize"},
            {"accounts.google.com", "/o/oauth2/v2/auth"}
          ]

        _ ->
          false
      end
    else
      false
    end
  end

  defp location?(_), do: false

  defp cookies?(cookies) when is_list(cookies),
    do: length(cookies) <= 8 and Enum.all?(cookies, &cookie?/1)

  defp cookies?(_), do: false

  defp cookie?(
         %{
           "name" => name,
           "value" => value,
           "max_age" => age,
           "secure" => true,
           "http_only" => true,
           "same_site" => "Lax",
           "path" => "/"
         } = cookie
       )
       when map_size(cookie) == 7 and is_binary(name) and is_binary(value) do
    String.valid?(name) and byte_size(name) <= 64 and
      (name == ChatOverlay.Session.cookie_name() or
         Regex.match?(~r/\A__Host-chat_overlay_oauth_[a-f0-9]{32}\z/, name)) and
      byte_size(value) <= 8192 and String.valid?(value) and
      not String.contains?(value, ["\r", "\n", <<0>>]) and
      (is_nil(age) or (is_integer(age) and age in 0..604_800))
  end

  defp cookie?(_), do: false

  defp public_json?(map) when is_map(map),
    do:
      Enum.all?(map, fn {key, value} ->
        is_binary(key) and String.valid?(key) and
          key not in [
            "access_token",
            "refresh_token",
            "encrypted_tokens",
            "client_secret",
            "encryption_key",
            "db_password"
          ] and public_json?(value)
      end)

  defp public_json?(list) when is_list(list), do: Enum.all?(list, &public_json?/1)
  defp public_json?(value) when is_binary(value), do: String.valid?(value)
  defp public_json?(value), do: is_nil(value) or is_number(value) or is_boolean(value)
end
