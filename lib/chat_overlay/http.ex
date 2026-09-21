defmodule ChatOverlay.HTTP do
  @moduledoc "Bandit listener. HTTP/1 behind the operator's TLS proxy."
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def port, do: GenServer.call(__MODULE__, :port)

  def init(_) do
    {:ok, pid} =
      Bandit.start_link(
        plug: ChatOverlay.Web,
        scheme: :http,
        port: Application.fetch_env!(:chat_overlay, :port),
        ip: Application.fetch_env!(:chat_overlay, :bind),
        startup_log: false,
        http_1_options: [
          max_request_line_length: 2048,
          max_header_length: 2048,
          max_header_count: 30,
          max_requests: 100
        ],
        http_2_options: [enabled: false],
        http_options: [compress: false, log_protocol_errors: false],
        thousand_island_options: [
          num_acceptors: 4,
          num_connections: 128,
          read_timeout: 5000,
          transport_options: [send_timeout: 5000, send_timeout_close: true]
        ]
      )

    {:ok, pid}
  end

  def handle_call(:port, _, pid) do
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    {:reply, port, pid}
  end

  def headers(type),
    do: [
      {"content-type", type},
      {"cache-control", "no-store"},
      {"x-content-type-options", "nosniff"},
      {"referrer-policy", "no-referrer"},
      {"content-security-policy",
       "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' https://static-cdn.jtvnw.net; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"},
      {"permissions-policy", "camera=(), microphone=(), geolocation=()"}
    ]
end
