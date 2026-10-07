defmodule ChatOverlay.Media do
  @moduledoc """
  Media management for alerts (audio and emoji/sticker images).
  Provides strict MIME/extension validation, size & quota enforcement,
  external URL sanitization, and S3/Cloudflare R2 Presigned PUT URL generation
  using AWS SigV4.

  Implements request validation from ADR 0003; actual-format validation (SEC-17)
  remains tracked separately in #49.
  """

  @max_audio_bytes 2_097_152
  @max_image_bytes 524_288
  @default_user_quota 10_485_760

  @audio_types %{
    ".mp3" => "audio/mpeg",
    ".ogg" => "audio/ogg",
    ".wav" => "audio/wav",
    ".webm" => "audio/webm"
  }

  @image_types %{
    ".webp" => "image/webp",
    ".png" => "image/png",
    ".gif" => "image/gif"
  }

  @doc """
  Returns the max allowed bytes for a given category (:audio or :image).
  """
  @spec max_bytes(atom()) :: non_neg_integer()
  def max_bytes(:audio), do: @max_audio_bytes
  def max_bytes(:image), do: @max_image_bytes

  @doc """
  Default quota in bytes per creator (10 MB).
  """
  @spec default_quota() :: non_neg_integer()
  def default_quota, do: @default_user_quota

  @doc """
  Validates a requested media upload.
  Rejects unlisted extensions, mismatched MIME types, and explicitly prohibits `.svg`.
  Enforces category-specific size limits and user remaining storage quota.
  """
  @spec validate_upload_request(map(), non_neg_integer(), non_neg_integer()) ::
          {:ok, %{category: atom(), ext: String.t(), mime: String.t(), key: String.t()}}
          | {:error, term()}
  def validate_upload_request(params, current_usage_bytes, max_quota_bytes \\ @default_user_quota)
      when is_map(params) and is_integer(current_usage_bytes) and is_integer(max_quota_bytes) do
    filename = params["filename"] || params[:filename] || ""
    content_type = params["content_type"] || params[:content_type] || ""
    size = params["size"] || params[:size] || 0

    with true <- is_binary(filename) and byte_size(filename) in 1..255,
         true <- is_binary(content_type) and byte_size(content_type) in 1..64,
         true <- is_integer(size) and size > 0,
         {:ok, category, ext} <- classify_extension(filename),
         {:ok, mime} <- match_mime(ext, content_type),
         true <- size <= max_bytes(category) || {:error, :file_too_large},
         true <- current_usage_bytes + size <= max_quota_bytes || {:error, :quota_exceeded} do
      uuid = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      sanitized_filename = sanitize_name(filename)
      key = "#{to_string(category)}/#{uuid}_#{sanitized_filename}"

      {:ok,
       %{
         category: category,
         ext: ext,
         mime: mime,
         key: key,
         size: size
       }}
    else
      false -> {:error, :invalid_parameters}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates an external URL for media (Discord CDN, Dropbox, web).
  Ensures HTTPS, permitted audio/image extension, and non-private network destination.
  """
  @spec validate_external_url(String.t(), atom()) :: {:ok, String.t()} | {:error, term()}
  def validate_external_url(url, expected_category)
      when is_binary(url) and expected_category in [:audio, :image] do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, path: path} when is_binary(host) and is_binary(path) ->
        with {:ok, category, _ext} <- classify_extension(path),
             true <- category == expected_category || {:error, :category_mismatch},
             true <- public_host?(host) || {:error, :destination_rejected} do
          {:ok, url}
        else
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  @doc """
  Generates an S3 / Cloudflare R2 Presigned PUT URL using AWS Signature Version 4 (SigV4).
  Does not require third-party AWS SDKs; implemented with native Erlang/OTP `:crypto`.
  """
  @spec generate_presigned_put(map()) :: {:ok, map()} | {:error, term()}
  def generate_presigned_put(config) when is_map(config) do
    endpoint = config[:endpoint] || config["endpoint"]
    bucket = config[:bucket] || config["bucket"]
    key = config[:key] || config["key"]
    content_type = config[:content_type] || config["content_type"]
    access_key_id = config[:access_key_id] || config["access_key_id"]
    secret_access_key = config[:secret_access_key] || config["secret_access_key"]
    region = config[:region] || config["region"] || "auto"
    expires_in = config[:expires_in] || config["expires_in"] || 300
    public_cdn_base = config[:public_cdn_base] || config["public_cdn_base"]

    with true <- is_binary(endpoint) and is_binary(bucket) and is_binary(key),
         true <- is_binary(access_key_id) and is_binary(secret_access_key) do
      now = DateTime.utc_now()
      date_stamp = Calendar.strftime(now, "%Y%m%d")
      amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")

      uri = URI.parse(endpoint)
      host = uri.host
      service = "s3"
      credential_scope = "#{date_stamp}/#{region}/#{service}/aws4_request"

      canonical_uri = "/" <> bucket <> "/" <> URI.encode(key)

      size = config[:size] || config["size"]

      upload_headers =
        if is_integer(size) and size > 0 and is_binary(content_type) do
          [
            {"content-length", to_string(size)},
            {"content-type", content_type},
            {"host", host},
            {"if-none-match", "*"}
          ]
        else
          [{"host", host}]
        end

      signed_headers = Enum.map_join(upload_headers, ";", &elem(&1, 0))
      canonical_headers = Enum.map_join(upload_headers, "", fn {k, v} -> "#{k}:#{v}\n" end)

      query_params = [
        {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
        {"X-Amz-Credential", "#{access_key_id}/#{credential_scope}"},
        {"X-Amz-Date", amz_date},
        {"X-Amz-Expires", to_string(expires_in)},
        {"X-Amz-SignedHeaders", signed_headers}
      ]

      canonical_query =
        Enum.map_join(query_params, "&", fn {k, v} ->
          "#{URI.encode(k, &URI.char_unreserved?/1)}=#{URI.encode(v, &URI.char_unreserved?/1)}"
        end)

      payload_hash = "UNSIGNED-PAYLOAD"

      canonical_request =
        Enum.join(
          [
            "PUT",
            canonical_uri,
            canonical_query,
            canonical_headers,
            signed_headers,
            payload_hash
          ],
          "\n"
        )

      string_to_sign =
        Enum.join(
          [
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            :crypto.hash(:sha256, canonical_request) |> Base.encode16(case: :lower)
          ],
          "\n"
        )

      signing_key = derive_signing_key(secret_access_key, date_stamp, region, service)

      signature =
        :crypto.mac(:hmac, :sha256, signing_key, string_to_sign)
        |> Base.encode16(case: :lower)

      upload_url =
        "#{endpoint}#{canonical_uri}?#{canonical_query}&X-Amz-Signature=#{signature}"

      public_url =
        if public_cdn_base && public_cdn_base != "" do
          String.trim_trailing(public_cdn_base, "/") <> "/" <> URI.encode(key)
        else
          "#{endpoint}#{canonical_uri}"
        end

      handle = config[:handle] || config["handle"]
      size = config[:size] || config["size"]
      category = config[:category] || config["category"]

      upload_token =
        if is_binary(handle) and is_integer(size) and (is_atom(category) or is_binary(category)) do
          case generate_upload_token(handle, key, size, category) do
            {:ok, token} -> token
            _ -> nil
          end
        else
          nil
        end

      result = %{
        upload_url: upload_url,
        public_url: public_url,
        key: key,
        content_type: content_type,
        expires_in: expires_in
      }

      result =
        if upload_token do
          Map.put(result, :upload_token, upload_token)
        else
          result
        end

      {:ok, result}
    else
      _ -> {:error, :invalid_s3_configuration}
    end
  end

  @doc """
  Returns R2/S3 configuration map resolved from environment variables and application env.
  """
  @spec r2_config() :: map()
  def r2_config do
    %{
      endpoint:
        System.get_env("R2_ENDPOINT") ||
          Application.get_env(:chat_overlay, :r2_endpoint),
      bucket:
        System.get_env("R2_BUCKET") ||
          Application.get_env(:chat_overlay, :r2_bucket),
      access_key_id:
        System.get_env("R2_ACCESS_KEY_ID") ||
          Application.get_env(:chat_overlay, :r2_access_key_id),
      secret_access_key:
        System.get_env("R2_SECRET_ACCESS_KEY") ||
          Application.get_env(:chat_overlay, :r2_secret_access_key),
      public_cdn_base:
        System.get_env("R2_PUBLIC_CDN") ||
          Application.get_env(
            :chat_overlay,
            :r2_public_cdn
          ),
      region:
        System.get_env("R2_REGION") ||
          Application.get_env(:chat_overlay, :r2_region, "auto")
    }
  end

  def configured? do
    config = r2_config()
    quarantine = quarantine_config()

    System.get_env("MEDIA_UPLOADS_SEALED") != "1" and
      Enum.all?([:access_key_id, :secret_access_key, :bucket], fn key ->
        is_binary(quarantine[key]) and byte_size(quarantine[key]) in 1..256
      end) and https_base?(config[:endpoint]) and https_base?(config[:public_cdn_base]) and
      is_binary(quarantine[:bucket]) and quarantine[:bucket] != config[:bucket] and
      ChatOverlay.MediaCoordinator.configured?()
  end

  def quarantine_config do
    r2_config()
    |> Map.put(
      :access_key_id,
      System.get_env("R2_QUARANTINE_ACCESS_KEY_ID") ||
        Application.get_env(:chat_overlay, :r2_quarantine_access_key_id)
    )
    |> Map.put(
      :secret_access_key,
      System.get_env("R2_QUARANTINE_SECRET_ACCESS_KEY") ||
        Application.get_env(:chat_overlay, :r2_quarantine_secret_access_key)
    )
    |> Map.put(
      :bucket,
      System.get_env("R2_QUARANTINE_BUCKET") ||
        Application.get_env(:chat_overlay, :r2_quarantine_bucket)
    )
    |> Map.delete(:public_cdn_base)
  end

  defp https_base?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: 443, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp https_base?(_), do: false

  @doc """
  Generates an S3 / Cloudflare R2 Presigned DELETE URL using AWS Signature Version 4 (SigV4).
  Does not require third-party AWS SDKs; implemented with native Erlang/OTP `:crypto`.
  """
  @spec generate_presigned_delete(map()) :: {:ok, map()} | {:error, term()}
  def generate_presigned_delete(config) when is_map(config),
    do: generate_presigned_metadata(config, "DELETE")

  defp generate_presigned_metadata(config, method) do
    endpoint = config[:endpoint] || config["endpoint"]
    bucket = config[:bucket] || config["bucket"]
    key = config[:key] || config["key"]
    access_key_id = config[:access_key_id] || config["access_key_id"]
    secret_access_key = config[:secret_access_key] || config["secret_access_key"]
    region = config[:region] || config["region"] || "auto"
    expires_in = config[:expires_in] || config["expires_in"] || 300

    with true <- is_binary(endpoint) and is_binary(bucket) and is_binary(key),
         true <- is_binary(access_key_id) and is_binary(secret_access_key) do
      now = DateTime.utc_now()
      date_stamp = Calendar.strftime(now, "%Y%m%d")
      amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")

      uri = URI.parse(endpoint)
      host = uri.host
      service = "s3"
      credential_scope = "#{date_stamp}/#{region}/#{service}/aws4_request"

      canonical_uri = "/" <> bucket <> "/" <> URI.encode(key)

      query_params = [
        {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
        {"X-Amz-Credential", "#{access_key_id}/#{credential_scope}"},
        {"X-Amz-Date", amz_date},
        {"X-Amz-Expires", to_string(expires_in)},
        {"X-Amz-SignedHeaders", "host"}
      ]

      canonical_query =
        Enum.map_join(query_params, "&", fn {k, v} ->
          "#{URI.encode(k, &URI.char_unreserved?/1)}=#{URI.encode(v, &URI.char_unreserved?/1)}"
        end)

      canonical_headers = "host:#{host}\n"
      signed_headers = "host"
      payload_hash = "UNSIGNED-PAYLOAD"

      canonical_request =
        Enum.join(
          [
            method,
            canonical_uri,
            canonical_query,
            canonical_headers,
            signed_headers,
            payload_hash
          ],
          "\n"
        )

      string_to_sign =
        Enum.join(
          [
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            :crypto.hash(:sha256, canonical_request) |> Base.encode16(case: :lower)
          ],
          "\n"
        )

      signing_key = derive_signing_key(secret_access_key, date_stamp, region, service)

      signature =
        :crypto.mac(:hmac, :sha256, signing_key, string_to_sign)
        |> Base.encode16(case: :lower)

      delete_url =
        "#{endpoint}#{canonical_uri}?#{canonical_query}&X-Amz-Signature=#{signature}"

      {:ok,
       %{
         delete_url: delete_url,
         key: key,
         expires_in: expires_in
       }}
    else
      _ -> {:error, :invalid_s3_configuration}
    end
  end

  @doc """
  Generates a presigned DELETE URL for the given key using default R2 configuration.
  """
  @spec presigned_delete_url(String.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def presigned_delete_url(key, opts \\ %{})

  def presigned_delete_url(key, opts) when is_binary(key) and is_list(opts) do
    presigned_delete_url(key, Enum.into(opts, %{}))
  end

  def presigned_delete_url(key, opts) when is_binary(key) and is_map(opts) do
    config =
      r2_config()
      |> Map.put(:key, key)
      |> Map.merge(opts)

    generate_presigned_delete(config)
  end

  def presigned_delete_url(_, _), do: {:error, :invalid_parameters}

  @doc """
  Generates an authenticated AEAD upload token binding handle, key, size, and category.
  Prevents client tampering with media size or profile associations.
  """
  @spec generate_upload_token(String.t(), String.t(), non_neg_integer(), atom() | String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_upload_token(handle, key, size, category)
      when is_binary(handle) and is_binary(key) and is_integer(size) and size >= 0 do
    secret = ChatOverlay.OAuth.encryption_key()

    payload =
      ChatOverlay.JSON.encode(%{
        "handle" => handle,
        "key" => key,
        "size" => size,
        "category" => to_string(category),
        "expires_at" => System.system_time(:second) + 300
      })

    ChatOverlay.Crypto.encrypt_aead(payload, secret, "media_upload_token")
  end

  def generate_upload_token(_, _, _, _), do: {:error, :invalid_parameters}

  @doc """
  Verifies an AEAD upload token against handle and key. Returns verified size and category.
  """
  @spec verify_upload_token(String.t(), String.t(), String.t()) ::
          {:ok, %{size: non_neg_integer(), category: String.t()}} | {:error, term()}
  def verify_upload_token(token, handle, key)
      when is_binary(token) and byte_size(token) <= 8192 and is_binary(handle) and is_binary(key) do
    secret = ChatOverlay.OAuth.encryption_key()

    with {:ok, json} <- ChatOverlay.Crypto.decrypt_aead(token, secret, "media_upload_token"),
         {:ok, data} when is_map(data) <- ChatOverlay.JSON.decode(json),
         true <-
           data["handle"] == handle and data["key"] == key and is_integer(data["size"]) and
             data["size"] > 0 and data["category"] in ["audio", "image"] and
             is_integer(data["expires_at"]) and data["expires_at"] > System.system_time(:second) and
             data["expires_at"] <= System.system_time(:second) + 300 do
      {:ok, %{size: data["size"], category: data["category"]}}
    else
      _ -> {:error, :invalid_upload_token}
    end
  end

  def verify_upload_token(_, _, _), do: {:error, :invalid_upload_token}

  def public_url(key) when is_binary(key) do
    config = r2_config()
    base = config[:public_cdn_base]

    if is_binary(base) and String.starts_with?(base, "https://") do
      {:ok, String.trim_trailing(base, "/") <> "/" <> URI.encode(key)}
    else
      {:error, :invalid_s3_configuration}
    end
  end

  # HEAD checks the stored size and declared type, not its actual format.
  def verify_object(object) do
    with {:ok, signed} <-
           generate_presigned_metadata(Map.put(r2_config(), :key, object["key"]), "HEAD"),
         {:ok, 200, headers, _} <- storage_request("HEAD", signed.delete_url),
         true <- Enum.count(headers, fn {k, _} -> String.downcase(k) == "content-length" end) == 1,
         {_, size} <- Enum.find(headers, fn {k, _} -> String.downcase(k) == "content-length" end),
         {_, mime} <- Enum.find(headers, fn {k, _} -> String.downcase(k) == "content-type" end),
         true <- size == to_string(object["size"]) and mime == object["mime"] do
      :ok
    else
      _ -> {:error, :stored_object_mismatch}
    end
  end

  def delete_object(key) do
    with {:ok, signed} <- presigned_delete_url(key),
         {:ok, status, _, _} <- storage_request("DELETE", signed.delete_url),
         true <- status in [200, 204, 404] do
      :ok
    else
      _ -> {:error, :storage_cleanup_failed}
    end
  end

  defp storage_request(method, url) do
    client =
      Application.get_env(:chat_overlay, :media_http_client, &ChatOverlay.Net.storage_request/2)

    client.(method, url)
  end

  # Helpers

  defp classify_extension(filename) when is_binary(filename) do
    ext = Path.extname(filename) |> String.downcase()

    cond do
      ext == ".svg" ->
        {:error, :svg_prohibited_for_security}

      Map.has_key?(@audio_types, ext) ->
        {:ok, :audio, ext}

      Map.has_key?(@image_types, ext) ->
        {:ok, :image, ext}

      true ->
        {:error, :unsupported_media_type}
    end
  end

  defp match_mime(ext, content_type) do
    expected_mime = Map.get(@audio_types, ext) || Map.get(@image_types, ext)
    normalized = String.downcase(String.trim(content_type))

    # Accept standard and common MIME aliases
    if normalized == expected_mime or
         (ext == ".wav" and normalized == "audio/x-wav") or
         (ext == ".ogg" and normalized == "application/ogg") do
      {:ok, expected_mime}
    else
      {:error, :mismatched_content_type}
    end
  end

  defp sanitize_name(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^a-zA-Z0-9_\-\.]/, "_")
    |> String.replace("..", "_")
    |> String.slice(0, 64)
  end

  defp derive_signing_key(secret, date, region, service) do
    k_date = :crypto.mac(:hmac, :sha256, "AWS4" <> secret, date)
    k_region = :crypto.mac(:hmac, :sha256, k_date, region)
    k_service = :crypto.mac(:hmac, :sha256, k_region, service)
    :crypto.mac(:hmac, :sha256, k_service, "aws4_request")
  end

  defp public_host?(host) when is_binary(host) do
    if Application.get_env(:chat_overlay, :skip_dns_validation, false) do
      true
    else
      case :inet.getaddrs(String.to_charlist(host), :inet) do
        {:ok, addresses} when addresses != [] ->
          Enum.all?(addresses, &ChatOverlay.Net.public_ip?/1)

        _ ->
          false
      end
    end
  end
end
