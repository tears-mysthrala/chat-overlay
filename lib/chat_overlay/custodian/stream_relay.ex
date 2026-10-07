defmodule ChatOverlay.Custodian.StreamRelay do
  @moduledoc "One typed SSE subscription over mTLS. The private stream owns source demand and revocation."
  alias ChatOverlay.Custodian.{Client, Protocol}
  @max_chunk 2_097_152

  def call(public, request) do
    with :ok <- Protocol.validate(request), {:ok, private} <- Client.open() do
      try do
        with {:ok, private, ref} <-
               Mint.HTTP.request(
                 private,
                 "POST",
                 "/v1/events",
                 [{"content-type", "application/json"}],
                 ChatOverlay.JSON.encode(request)
               ),
             {:ok, private, pending} <-
               headers(private, ref, nil, false, [], System.monotonic_time(:millisecond) + 5000) do
          public =
            public
            |> Plug.Conn.merge_resp_headers(
              ChatOverlay.HTTP.headers("text/event-stream; charset=utf-8")
            )
            |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
            |> Plug.Conn.send_chunked(200)

          case forward(public, pending) do
            {:ok, public} -> relay(public, private, ref)
            _ -> public
          end
        else
          {:error, status} when status in [401, 403, 404, 503] -> reject(public, status)
          _ -> reject(public, 503)
        end
      after
        Mint.HTTP.close(private)
      end
    else
      _ -> reject(public, 503)
    end
  end

  defp headers(conn, ref, status, valid_type, pending, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, 503}
    else
      case Mint.HTTP.recv(conn, 0, remaining) do
        {:ok, conn, responses} ->
          {status, valid_type, pending, received_headers} =
            Enum.reduce(responses, {status, valid_type, pending, false}, fn
              {:status, ^ref, code}, {_, t, p, h} ->
                {code, t, p, h}

              {:headers, ^ref, headers}, {s, _, p, _} ->
                type = Enum.filter(headers, &(elem(&1, 0) == "content-type"))
                {s, type == [{"content-type", "text/event-stream; charset=utf-8"}], p, true}

              {:data, ^ref, bytes}, {s, t, p, h} ->
                {s, t, p ++ [bytes], h}

              _, acc ->
                acc
            end)

          cond do
            IO.iodata_length(pending) > @max_chunk -> {:error, 503}
            received_headers and status == 200 and valid_type -> {:ok, conn, pending}
            received_headers and status in [401, 403, 404, 503] -> {:error, status}
            received_headers -> {:error, 503}
            true -> headers(conn, ref, status, valid_type, pending, deadline)
          end

        _ ->
          {:error, 503}
      end
    end
  end

  defp relay(public, private, ref) do
    receive do
      {:tcp_closed, _} -> public
      {:tcp_error, _, _} -> public
      {:ssl_closed, _} -> public
      {:ssl_error, _, _} -> public
    after
      0 ->
        case Mint.HTTP.recv(private, 0, 1000) do
          {:ok, private, responses} ->
            parts = for {:data, ^ref, bytes} <- responses, do: bytes
            done = Enum.any?(responses, &match?({:done, ^ref}, &1))

            case forward(public, parts) do
              {:ok, public} when not done -> relay(public, private, ref)
              {:ok, public} -> public
              _ -> public
            end

          {:error, private, %Mint.TransportError{reason: :timeout}, _} ->
            relay(public, private, ref)

          {:error, private, %Mint.TransportError{reason: :timeout}} ->
            relay(public, private, ref)

          _ ->
            public
        end
    end
  end

  defp forward(public, []), do: {:ok, public}

  defp forward(public, parts) do
    if IO.iodata_length(parts) <= @max_chunk,
      do: Plug.Conn.chunk(public, parts),
      else: {:error, :response_rejected}
  end

  defp reject(conn, status),
    do:
      conn
      |> Plug.Conn.merge_resp_headers(ChatOverlay.HTTP.headers("text/plain"))
      |> Plug.Conn.send_resp(status, "Stream unavailable")
end
