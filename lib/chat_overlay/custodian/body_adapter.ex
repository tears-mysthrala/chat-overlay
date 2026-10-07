defmodule ChatOverlay.Custodian.BodyAdapter do
  @moduledoc false
  @behaviour Plug.Conn.Adapter

  # An already bounded domain document, not a socket or an arbitrary HTTP request.
  def read_req_body(body, options) do
    length = Keyword.get(options, :length, 8_000_000)

    if byte_size(body) <= length,
      do: {:ok, body, ""},
      else:
        {:more, binary_part(body, 0, length), binary_part(body, length, byte_size(body) - length)}
  end

  def send_resp(body, _, _, response), do: {:ok, IO.iodata_to_binary(response), body}
  def send_file(_, _, _, _, _, _), do: raise("Files are not custodian operations")
  def send_chunked(_, _, _), do: raise("Streaming is not a document operation")
  def chunk(_, _), do: {:error, :not_supported}
  def inform(_, _, _), do: {:error, :not_supported}
  def upgrade(_, _, _), do: {:error, :not_supported}
  def get_peer_data(_), do: %{address: {192, 0, 2, 1}, port: 0, ssl_cert: nil}
  def get_http_protocol(_), do: :"HTTP/1.1"
end
