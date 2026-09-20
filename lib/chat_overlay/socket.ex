defmodule ChatOverlay.Socket do
  @moduledoc "Bounded passive Mint WebSocket; caller owns its socket and deadline."
  @limit 262_144
  def open(path) do
    with {:ok, conn} <- ChatOverlay.Net.open("eventsub.wss.twitch.tv") do
      upgrade(conn, path)
    end
  end

  def upgrade(conn, path, scheme \\ :wss) do
    case Mint.WebSocket.upgrade(scheme, conn, path, []) do
      {:ok, next, ref} ->
        case handshake(next, ref, nil, [], [], System.monotonic_time(:millisecond) + 10_000) do
          {:ok, _} = result ->
            result

          error ->
            Mint.HTTP.close(conn)
            error
        end

      _ ->
        Mint.HTTP.close(conn)
        {:error, :upgrade_failed}
    end
  end

  def close(s), do: Mint.HTTP.close(s.conn)

  defp handshake(conn, ref, status, headers, data, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      case Mint.HTTP.recv(conn, 0, remaining) do
        {:ok, conn, responses} ->
          {status, headers, data, done} =
            Enum.reduce(responses, {status, headers, data, false}, fn
              {:status, ^ref, code}, {_, h, d, f} -> {code, h, d, f}
              {:headers, ^ref, hs}, {s, _, d, f} -> {s, hs, d, f}
              {:data, ^ref, bytes}, {s, h, d, f} -> {s, h, [bytes | d], f}
              {:done, ^ref}, {s, h, d, _} -> {s, h, d, true}
              _, acc -> acc
            end)

          cond do
            status not in [nil, 101] ->
              {:error, :upgrade_failed}

            IO.iodata_length(data) > @limit ->
              {:error, :too_large}

            done ->
              with {:ok, conn, ws} <-
                     Mint.WebSocket.new(conn, ref, status, headers, mode: :passive),
                   {:ok, s} <-
                     decode(
                       %{conn: conn, ref: ref, ws: ws, frames: []},
                       data |> Enum.reverse() |> IO.iodata_to_binary()
                     ) do
                {:ok, s}
              else
                _ -> {:error, :upgrade_failed}
              end

            true ->
              handshake(conn, ref, status, headers, data, deadline)
          end

        _ ->
          {:error, :upgrade_failed}
      end
    else
      {:error, :upgrade_timeout}
    end
  end

  def recv(s, timeout), do: recv_until(s, System.monotonic_time(:millisecond) + timeout)
  defp recv_until(%{frames: [frame | rest]} = s, _), do: {:ok, frame, %{s | frames: rest}}

  defp recv_until(s, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      case Mint.WebSocket.recv(s.conn, 0, remaining) do
        {:ok, conn, responses} ->
          data = for {:data, _, bytes} <- responses, into: "", do: bytes
          with {:ok, s} <- decode(%{s | conn: conn}, data), do: recv_until(s, deadline)

        {:error, _, :timeout, _} ->
          timeout_result(s)

        {:error, _, %Mint.TransportError{reason: :timeout}, _} ->
          timeout_result(s)

        _ ->
          {:error, :connection_lost}
      end
    else
      timeout_result(s)
    end
  end

  # Version-pinned Mint decoder state distinguishes an empty drain from a lost fragment.
  defp timeout_result(%{ws: %Mint.WebSocket{buffer: <<>>, fragment: nil}}), do: {:error, :timeout}
  defp timeout_result(_), do: {:error, :incomplete_frame}

  def decode(s, data) do
    if byte_size(data) + :erlang.external_size(s.ws) <= @limit do
      case Mint.WebSocket.decode(s.ws, data) do
        {:ok, ws, frames} when length(frames) <= 128 ->
          if :erlang.external_size({ws, frames}) <= @limit,
            do: {:ok, %{s | ws: ws, frames: s.frames ++ frames}},
            else: {:error, :too_large}

        _ ->
          {:error, :invalid_frame}
      end
    else
      {:error, :too_large}
    end
  end

  def pong(s, bytes) do
    with {:ok, ws, encoded} <- Mint.WebSocket.encode(s.ws, {:pong, bytes}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(s.conn, s.ref, encoded) do
      {:ok, %{s | ws: ws, conn: conn}}
    else
      _ -> {:error, :connection_lost}
    end
  end
end
