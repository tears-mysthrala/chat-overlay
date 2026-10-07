defmodule ChatOverlay.Custodian.RPC do
  @moduledoc "One authenticated TLS endpoint for the closed domain protocol."
  @behaviour Plug
  alias ChatOverlay.Custodian.{Operations, Protocol}
  def init(options), do: options

  def call(%{method: "POST", path_info: ["v1", "upload"]} = conn, _) do
    with true <- conn.query_string == "",
         %{ssl_cert: cert} when is_binary(cert) <- Plug.Conn.get_peer_data(conn),
         [metadata] <- Plug.Conn.get_req_header(conn, "x-custodian-request"),
         true <- byte_size(metadata) <= 16_384,
         {:ok, %{"operation" => "media.upload", "arguments" => args} = request} <-
           Protocol.decode(metadata),
         [mime] <- Plug.Conn.get_req_header(conn, "content-type"),
         true <- mime == args["mime"],
         {:ok, %{"kind" => "upload_permit", "size" => size}} <-
           Operations.execute(Map.put(request, "operation", "media.upload_authorize")),
         {:ok, bytes, conn} <- Plug.Conn.read_body(conn, length: size, read_timeout: 4000),
         true <- byte_size(bytes) == size,
         {:ok, result} <- Operations.upload(request, bytes) do
      reply(conn, 200, result)
    else
      _ -> reply(conn, 400, %{"ok" => false})
    end
  end

  def call(conn, _) do
    with "POST" <- conn.method,
         true <- conn.path_info in [["v1", "operation"], ["v1", "events"]],
         true <- conn.query_string == "",
         %{ssl_cert: cert} when is_binary(cert) <- Plug.Conn.get_peer_data(conn),
         ["application/json"] <- Plug.Conn.get_req_header(conn, "content-type"),
         {:ok, bytes, conn} <- Plug.Conn.read_body(conn, length: 65_536, read_timeout: 4000),
         {:ok, request} <- Protocol.decode(bytes) do
      dispatch(conn, request)
    else
      _ -> reply(conn, 400, %{"version" => 1, "kind" => "error", "error" => "request_rejected"})
    end
  end

  defp dispatch(
         %{path_info: ["v1", "events"]} = conn,
         %{"operation" => "events.subscribe", "arguments" => args}
       ) do
    case Operations.authorize_stream(args) do
      200 ->
        query = %{"view" => args["view"]}

        query =
          if args["capability"], do: Map.put(query, "token", args["capability"]), else: query

        conn = %{
          conn
          | query_string: URI.encode_query(query),
            # The mTLS peer identifies the frontend, not a local demo user.
            remote_ip: {192, 0, 2, 1},
            req_headers: if(args["cursor"], do: [{"last-event-id", args["cursor"]}], else: []),
            req_cookies: %{"chat_overlay_session" => args["session"]},
            cookies: %{"chat_overlay_session" => args["session"]}
        }

        conn = Plug.Conn.put_private(conn, :custodian_reader, args["view"] == "reader")
        ChatOverlay.RequestScope.request(fn -> ChatOverlay.Stream.call(conn, args["handle"]) end)

      status ->
        reply(conn, status, %{"ok" => false})
    end
  end

  defp dispatch(%{path_info: ["v1", "operation"]} = conn, request) do
    case Operations.execute(request) do
      {:ok, result} -> reply(conn, 200, result)
      _ -> reply(conn, 400, %{"version" => 1, "kind" => "error", "error" => "request_rejected"})
    end
  end

  defp dispatch(conn, _), do: reply(conn, 400, %{"ok" => false})

  defp reply(conn, status, result),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.put_resp_header("cache-control", "no-store")
      |> Plug.Conn.send_resp(status, ChatOverlay.JSON.encode(result))
end

defmodule ChatOverlay.Custodian.Listener do
  @moduledoc "mTLS listener with bounded HTTP resources; no cleartext listener or optional certificate."
  use GenServer
  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def port(pid), do: GenServer.call(pid, :port)

  def init(options) do
    {:ok, listener} =
      Bandit.start_link(
        plug: ChatOverlay.Custodian.RPC,
        scheme: :https,
        ip: Keyword.fetch!(options, :ip),
        port: Keyword.fetch!(options, :port),
        certfile: Keyword.fetch!(options, :certfile),
        keyfile: Keyword.fetch!(options, :keyfile),
        startup_log: false,
        http_1_options: [
          max_request_line_length: 256,
          max_header_length: 16_384,
          max_header_count: 16,
          max_requests: 100
        ],
        http_2_options: [enabled: false],
        http_options: [compress: false, log_protocol_errors: false],
        thousand_island_options: [
          num_acceptors: 2,
          # ThousandIsland applies this bound per acceptor: 2 * 256 matches
          # the public listener's 4 * 128, while SSE admission stays at 100.
          num_connections: 256,
          read_timeout: 5000,
          transport_options: [
            cacertfile: Keyword.fetch!(options, :cacertfile),
            verify: :verify_peer,
            fail_if_no_peer_cert: true,
            versions: [:"tlsv1.3", :"tlsv1.2"],
            send_timeout: 5000,
            send_timeout_close: true
          ]
        ]
      )

    {:ok, listener}
  end

  def handle_call(:port, _, listener) do
    {:ok, {_, port}} = ThousandIsland.listener_info(listener)
    {:reply, port, listener}
  end
end
