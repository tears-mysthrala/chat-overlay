defmodule ChatOverlay.Transport do
  @moduledoc "HTTPS detection through direct TLS or an explicitly trusted proxy peer."
  def secure?(conn) do
    conn.scheme == :https or
      (conn.remote_ip in Application.get_env(:chat_overlay, :trusted_proxy_ips, []) and
         Plug.Conn.get_req_header(conn, "x-forwarded-proto") == ["https"])
  end

  def parse_proxy_ips!(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(fn ip ->
      case :inet.parse_address(String.to_charlist(String.trim(ip))) do
        {:ok, address} -> address
        _ -> raise ArgumentError, "CHAT_TRUSTED_PROXY_IPS requires literal IP addresses"
      end
    end)
  end

  def requester(conn) do
    # The trusted proxy must replace client-supplied XFF with one verified address.
    # Ambiguous or invalid values share the peer's bounded quota.
    if conn.remote_ip in Application.get_env(:chat_overlay, :trusted_proxy_ips, []) do
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [value] ->
          case :inet.parse_address(String.to_charlist(String.trim(value))) do
            {:ok, ip} -> ip
            _ -> conn.remote_ip
          end

        _ ->
          conn.remote_ip
      end
    else
      conn.remote_ip
    end
  end

  def parse_origin!(nil), do: nil

  def parse_origin!(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, path: path, query: nil, fragment: nil} =
          uri
      when is_binary(host) and path in [nil, "", "/"] ->
        URI.to_string(%{uri | path: nil})

      _ ->
        raise ArgumentError,
              "CHAT_PUBLIC_ORIGIN requires an HTTPS origin without path or credentials"
    end
  end

  def origin(conn) do
    Application.get_env(:chat_overlay, :oauth_origin) ||
      if ChatOverlay.Session.loopback?(conn) and conn.host in ["localhost", "127.0.0.1", "::1"] do
        URI.to_string(%URI{
          scheme: if(secure?(conn), do: "https", else: "http"),
          host: conn.host,
          port: conn.port
        })
      end
  end

  def oauth_allowed?(conn) do
    is_binary(origin(conn)) and
      (secure?(conn) or
         (ChatOverlay.Session.loopback?(conn) and conn.host in ["localhost", "127.0.0.1", "::1"] and
            conn.remote_ip not in Application.get_env(:chat_overlay, :trusted_proxy_ips, []) and
            is_nil(Application.get_env(:chat_overlay, :oauth_origin))))
  end
end
