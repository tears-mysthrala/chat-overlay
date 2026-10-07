defmodule ChatOverlay.LocalMedia do
  @moduledoc "Bounded byte relay to the private local storage coordinator; no decoder or filesystem access."

  def backend,
    do:
      System.get_env("MEDIA_STORAGE") || Application.get_env(:chat_overlay, :media_storage, "r2")

  def max_bytes do
    value = System.get_env("MEDIA_LOCAL_MAX_BYTES", "268435456")

    case Integer.parse(value) do
      {n, ""} when n in 2_097_152..1_073_741_824 -> n
      _ -> 0
    end
  end

  def public_base do
    Application.get_env(:chat_overlay, :oauth_origin) || System.get_env("CHAT_PUBLIC_ORIGIN")
  end

  def upload_description(config) do
    with {:ok, token} <-
           ChatOverlay.Media.generate_upload_token(
             config[:handle],
             config[:key],
             config[:size],
             config[:category]
           ) do
      {:ok,
       %{
         upload_url: "/api/media/upload/" <> config[:handle],
         key: config[:key],
         content_type: config[:content_type],
         upload_token: token,
         upload_headers: %{"x-upload-key" => config[:key], "x-upload-token" => token}
       }}
    end
  end

  def request(method, bucket, key, body \\ "", mime \\ nil) do
    client = Application.get_env(:chat_overlay, :local_media_http_client, &local_request/5)
    client.(method, bucket, key, body, mime)
  end

  defp local_request(method, bucket, key, body, mime) do
    with true <- method in ["GET", "HEAD", "PUT"] and bucket in ["quarantine", "public"],
         true <-
           is_binary(key) and byte_size(key) <= 256 and
             not String.contains?(key, ["\r", "\n", <<0>>]),
         true <- is_binary(body) and byte_size(body) <= 2_097_152,
         {:ok, conn} <- ChatOverlay.MediaCoordinator.connect() do
      try do
        token = ChatOverlay.MediaCoordinator.token()
        headers = [{"authorization", "Bearer " <> token}, {"x-object-key", key}]
        headers = if mime, do: [{"content-type", mime} | headers], else: headers

        with {:ok, conn, ref} <-
               Mint.HTTP.request(conn, method, "/object/" <> bucket, headers, body) do
          receive_body(conn, ref, nil, [], [], 0, System.monotonic_time(:millisecond) + 10_000)
        else
          _ -> {:error, :local_storage_unavailable}
        end
      after
        Mint.HTTP.close(conn)
      end
    else
      _ -> {:error, :local_storage_unavailable}
    end
  rescue
    _ -> {:error, :local_storage_unavailable}
  end

  defp receive_body(conn, ref, status, headers, parts, size, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :local_storage_timeout}
    else
      case Mint.HTTP.recv(conn, 0, remaining) do
        {:ok, conn, responses} ->
          {status, headers, parts, size, done} =
            Enum.reduce(responses, {status, headers, parts, size, false}, fn
              {:status, ^ref, v}, {_, h, p, n, d} -> {v, h, p, n, d}
              {:headers, ^ref, v}, {s, _, p, n, d} -> {s, v, p, n, d}
              {:data, ^ref, v}, {s, h, p, n, d} -> {s, h, [v | p], n + byte_size(v), d}
              {:done, ^ref}, {s, h, p, n, _} -> {s, h, p, n, true}
              _, acc -> acc
            end)

          cond do
            size > 2_097_152 -> {:error, :local_storage_response_rejected}
            done -> {:ok, status, headers, parts |> Enum.reverse() |> IO.iodata_to_binary()}
            true -> receive_body(conn, ref, status, headers, parts, size, deadline)
          end

        _ ->
          {:error, :local_storage_unavailable}
      end
    end
  end
end
