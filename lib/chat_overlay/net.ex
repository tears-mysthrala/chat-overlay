defmodule ChatOverlay.Net do
  @moduledoc "Fixed destinations, pinned public IPs, verified TLS, bounded passive reads."
  @hosts ~w(api.twitch.tv id.twitch.tv eventsub.wss.twitch.tv www.googleapis.com api.kick.com)
  def open(host) when host in @hosts do
    with {:ok, addresses} <- :inet.getaddrs(String.to_charlist(host), :inet),
         true <- addresses != [] and Enum.all?(addresses, &public_ip?/1) do
      Mint.HTTP.connect(:https, hd(addresses), 443,
        hostname: host,
        protocols: [:http1],
        mode: :passive,
        max_header_list_size: 16_384,
        transport_opts: [
          timeout: 5000,
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          send_timeout: 5000,
          send_timeout_close: true
        ]
      )
    else
      _ -> {:error, :destination_rejected}
    end
  end

  def open(_), do: {:error, :destination_rejected}
  # IPv4 only for outbound connections. Deny non-global and special-purpose ranges.
  def public_ip?({a, b, c, d}) when a in 1..223 and b in 0..255 and c in 0..255 and d in 0..255 do
    not (a in [10, 127] or (a == 100 and b in 64..127) or (a == 169 and b == 254) or
           (a == 172 and b in 16..31) or (a == 192 and b in [0, 168]) or
           (a == 198 and (b in [18, 19] or (b == 51 and c == 100))) or
           (a == 203 and b == 0 and c == 113))
  end

  def public_ip?(_), do: false

  def request(host, method, path, headers \\ [], body \\ "") do
    with true <- valid_request?(method, path, headers), {:ok, conn} <- open(host) do
      try do
        case Mint.HTTP.request(
               conn,
               method,
               path,
               [{"accept", "application/json"} | headers],
               body
             ) do
          {:ok, conn, ref} ->
            receive_response(
              conn,
              ref,
              %{
                status: nil,
                headers: [],
                parts: [],
                size: 0,
                done: false,
                limit: body_limit(host)
              },
              System.monotonic_time(:millisecond) + 10_000
            )

          _ ->
            {:error, :upstream_unavailable}
        end
      after
        Mint.HTTP.close(conn)
      end
    else
      _ -> {:error, :upstream_unavailable}
    end
  rescue
    _ -> {:error, :upstream_unavailable}
  catch
    :exit, _ -> {:error, :upstream_unavailable}
  end

  defp valid_request?(method, path, headers) do
    method in ["GET", "POST"] and is_binary(path) and byte_size(path) <= 4096 and
      String.starts_with?(path, "/") and not String.contains?(path, ["\r", "\n", " "]) and
      Enum.all?(headers, fn {k, v} ->
        is_binary(k) and is_binary(v) and byte_size(v) <= 4096 and
          not String.contains?(v, ["\r", "\n", <<0>>])
      end)
  end

  defp receive_response(conn, ref, state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      case Mint.HTTP.recv(conn, 0, remaining) do
        {:ok, conn, responses} ->
          state =
            Enum.reduce(responses, state, fn
              {:status, ^ref, status}, s ->
                %{s | status: status}

              {:headers, ^ref, headers}, s ->
                %{s | headers: headers}

              {:data, ^ref, data}, s ->
                %{s | parts: [data | s.parts], size: s.size + byte_size(data)}

              {:done, ^ref}, s ->
                %{s | done: true}

              _, s ->
                s
            end)

          cond do
            state.size > state.limit ->
              {:error, :upstream_body_rejected}

            state.done ->
              {:ok, state.status, state.headers,
               state.parts |> Enum.reverse() |> IO.iodata_to_binary()}

            true ->
              receive_response(conn, ref, state, deadline)
          end

        _ ->
          {:error, :upstream_unavailable}
      end
    else
      {:error, :upstream_timeout}
    end
  end

  def body_limit("www.googleapis.com"), do: 2_097_152
  def body_limit(_), do: 262_144

  def token(source) do
    value = System.get_env(source["credential_env"] || "")

    if is_binary(value) and byte_size(value) in 1..4096 and
         not String.contains?(value, ["\r", "\n", <<0>>]),
       do: {:ok, value},
       else: {:error, :configuration_error}
  end

  def retry_after(headers, now \\ DateTime.utc_now()) do
    value = Enum.find_value(headers, fn {k, v} -> if k == "retry-after", do: v end) || ""

    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        max(seconds * 1000, 1000)

      _ ->
        case Regex.run(
               ~r/\A[A-Z][a-z]{2}, (\d{2}) ([A-Z][a-z]{2}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT\z/,
               value
             ) do
          [_, d, month, y, h, m, s] ->
            months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

            with index when is_integer(index) <- Enum.find_index(months, &(&1 == month)),
                 {:ok, date} <-
                   NaiveDateTime.new(
                     String.to_integer(y),
                     index + 1,
                     String.to_integer(d),
                     String.to_integer(h),
                     String.to_integer(m),
                     String.to_integer(s)
                   ) do
              max(DateTime.diff(DateTime.from_naive!(date, "Etc/UTC"), now, :millisecond), 1000)
            else
              _ -> 60_000
            end

          _ ->
            60_000
        end
    end
  end
end
