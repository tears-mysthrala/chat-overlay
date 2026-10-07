defmodule ChatOverlay.Custodian.Client do
  @moduledoc "Fixed operator endpoint, mutual TLS, bounded reads and no automatic mutation retries."
  alias ChatOverlay.Custodian.Protocol
  @deadline_ms 35_000

  def open do
    config = Application.fetch_env!(:chat_overlay, :custodian_client)
    connect(config)
  rescue
    _ -> {:error, :custodian_unavailable}
  end

  def call(request), do: exchange(request, nil)

  def upload(%{"operation" => "media.upload"} = request, bytes)
      when is_binary(bytes) and byte_size(bytes) <= 2_097_152, do: exchange(request, bytes)

  def upload(_, _), do: {:error, :request_rejected}

  defp exchange(request, bytes) do
    with :ok <- Protocol.validate(request),
         config when is_list(config) <- Application.get_env(:chat_overlay, :custodian_client),
         {:ok, conn} <- connect(config) do
      try do
        metadata = ChatOverlay.JSON.encode(request)

        {path, headers, body} =
          if is_nil(bytes) do
            {"/v1/operation", [{"content-type", "application/json"}], metadata}
          else
            if byte_size(metadata) > 16_384, do: raise("Upload metadata exceeds bound")

            {"/v1/upload",
             [{"content-type", request["arguments"]["mime"]}, {"x-custodian-request", metadata}],
             bytes}
          end

        with {:ok, conn, ref} <-
               Mint.HTTP.request(
                 conn,
                 "POST",
                 path,
                 headers,
                 body
               ) do
          receive_result(
            conn,
            ref,
            nil,
            [],
            0,
            System.monotonic_time(:millisecond) + @deadline_ms
          )
        else
          _ -> {:error, :custodian_unavailable}
        end
      after
        Mint.HTTP.close(conn)
      end
    else
      _ -> {:error, :custodian_unavailable}
    end
  rescue
    _ -> {:error, :custodian_unavailable}
  catch
    :exit, _ -> {:error, :custodian_unavailable}
  end

  defp connect(config) do
    hostname = Keyword.fetch!(config, :hostname)

    Mint.HTTP.connect(:https, Keyword.fetch!(config, :address), Keyword.fetch!(config, :port),
      hostname: hostname,
      protocols: [:http1],
      mode: :passive,
      max_header_list_size: 4096,
      transport_opts: [
        verify: :verify_peer,
        cacertfile: Keyword.fetch!(config, :cacertfile),
        certfile: Keyword.fetch!(config, :certfile),
        keyfile: Keyword.fetch!(config, :keyfile),
        server_name_indication: String.to_charlist(hostname),
        timeout: 3000,
        send_timeout: 5000,
        send_timeout_close: true
      ]
    )
  end

  defp receive_result(conn, ref, status, parts, size, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :custodian_unavailable}
    else
      case Mint.HTTP.recv(conn, 0, remaining) do
        {:ok, conn, responses} ->
          {status, parts, size, done} =
            Enum.reduce(responses, {status, parts, size, false}, fn
              {:status, ^ref, code}, {_, p, s, d} -> {code, p, s, d}
              {:data, ^ref, bytes}, {c, p, s, d} -> {c, [bytes | p], s + byte_size(bytes), d}
              {:done, ^ref}, {c, p, s, _} -> {c, p, s, true}
              _, acc -> acc
            end)

          cond do
            size > ChatOverlay.Custodian.Result.max_bytes() ->
              {:error, :response_rejected}

            done and status == 200 ->
              decode_result(parts |> Enum.reverse() |> IO.iodata_to_binary())

            done ->
              {:error, :request_rejected}

            true ->
              receive_result(conn, ref, status, parts, size, deadline)
          end

        _ ->
          {:error, :custodian_unavailable}
      end
    end
  end

  defp decode_result(bytes) do
    ChatOverlay.Custodian.Result.decode(bytes)
  end
end
