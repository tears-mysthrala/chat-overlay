defmodule ChatOverlay.MediaCoordinator do
  @moduledoc "Authenticated loopback control plane; no content or decoder process in the HTTP backend."

  def request(path, metadata) when path in ["/normalize", "/delete"] do
    client = Application.get_env(:chat_overlay, :media_coordinator_client, &local_request/2)
    client.(path, metadata)
  end

  def configured? do
    token =
      System.get_env("MEDIA_COORDINATOR_TOKEN") ||
        Application.get_env(:chat_overlay, :media_coordinator_token)

    is_binary(token) and Regex.match?(~r/\A[A-Za-z0-9_-]{43,128}\z/, token)
  end

  defp local_request(path, metadata) do
    token =
      System.get_env("MEDIA_COORDINATOR_TOKEN") ||
        Application.get_env(:chat_overlay, :media_coordinator_token)

    port = Application.get_env(:chat_overlay, :media_coordinator_port, 4199)

    with true <- configured?(),
         true <- is_integer(port) and port in 1024..65535,
         {:ok, conn} <-
           Mint.HTTP.connect(:http, {127, 0, 0, 1}, port,
             hostname: "localhost",
             protocols: [:http1],
             mode: :passive,
             max_header_list_size: 4096,
             transport_opts: [timeout: 1000, send_timeout: 1000, send_timeout_close: true]
           ) do
      try do
        with {:ok, conn, ref} <-
               Mint.HTTP.request(
                 conn,
                 "POST",
                 path,
                 [{"authorization", "Bearer " <> token}, {"content-type", "application/json"}],
                 ChatOverlay.JSON.encode(metadata)
               ) do
          receive_result(conn, ref, nil, "", System.monotonic_time(:millisecond) + 30_000)
        else
          _ -> {:error, :coordinator_unavailable}
        end
      after
        Mint.HTTP.close(conn)
      end
    else
      _ -> {:error, :coordinator_unavailable}
    end
  rescue
    _ -> {:error, :coordinator_unavailable}
  end

  defp receive_result(conn, ref, status, body, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :coordinator_timeout}
    else
      case Mint.HTTP.recv(conn, 0, remaining) do
        {:ok, conn, responses} ->
          {status, body, done} =
            Enum.reduce(responses, {status, body, false}, fn
              {:status, ^ref, value}, {_, b, d} -> {value, b, d}
              {:data, ^ref, data}, {s, b, d} -> {s, b <> data, d}
              {:done, ^ref}, {s, b, _} -> {s, b, true}
              _, acc -> acc
            end)

          cond do
            byte_size(body) > 2048 -> {:error, :coordinator_response_rejected}
            done and status == 200 -> ChatOverlay.JSON.decode(body)
            done -> {:error, :validation_failed}
            true -> receive_result(conn, ref, status, body, deadline)
          end

        _ ->
          {:error, :coordinator_unavailable}
      end
    end
  end
end
