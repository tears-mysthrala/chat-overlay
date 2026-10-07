import Config

if config_env() != :test do
  role = ChatOverlay.Custodian.Role.parse!(System.get_env("CHAT_ROLE"))
  config :chat_overlay, role: role

  if role != :frontend do
    backend =
      case System.get_env("CHAT_STORAGE") || if(config_env() == :dev, do: "json_demo", else: nil) do
        "json_demo" -> :json_demo
        "postgres" -> :postgres
        _ -> raise "CHAT_STORAGE must explicitly select json_demo or postgres"
      end

    config :chat_overlay, persistence_backend: backend

    if backend == :postgres do
      if System.get_env("CHAT_CONFIG"),
        do: raise("CHAT_CONFIG is incompatible with PostgreSQL storage")

      common = [
        hostname: System.fetch_env!("CHAT_DB_HOST"),
        port: String.to_integer(System.get_env("CHAT_DB_PORT", "5432")),
        database: System.fetch_env!("CHAT_DB_NAME"),
        pool_size: 2,
        ssl: true,
        ssl_opts: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(System.fetch_env!("CHAT_DB_HOST"))
        ]
      ]

      config :chat_overlay,
        postgres_runtime:
          common ++
            [username: "overlay_runtime", password: System.fetch_env!("CHAT_DB_RUNTIME_PASSWORD")],
        postgres_bootstrap:
          common ++
            [
              username: "overlay_bootstrap",
              password: System.fetch_env!("CHAT_DB_BOOTSTRAP_PASSWORD")
            ]
    end

    if backend == :json_demo do
      if path = System.get_env("CHAT_CONFIG") do
        document = ChatOverlay.Config.load_document!(path)

        config :chat_overlay,
          profiles: document["profiles"],
          media_objects: document["media_objects"]
      end
    end
  end

  if role in [:frontend, :custodian] do
    System.fetch_env!("CHAT_PUBLIC_ORIGIN")
    tls = System.fetch_env!("CHAT_CUSTODIAN_TLS_DIR")
    port = String.to_integer(System.get_env("CHAT_CUSTODIAN_PORT", "4200"))
    if port not in 1024..65535, do: raise("Invalid CHAT_CUSTODIAN_PORT")

    if role == :frontend do
      address =
        case System.get_env("CHAT_CUSTODIAN_ADDRESS") do
          nil ->
            System.fetch_env!("CHAT_CUSTODIAN_HOST")

          value ->
            case :inet.parse_address(String.to_charlist(value)) do
              {:ok, address} -> address
              _ -> raise("CHAT_CUSTODIAN_ADDRESS requires a literal IP")
            end
        end

      config :chat_overlay,
        custodian_client: [
          address: address,
          hostname: System.fetch_env!("CHAT_CUSTODIAN_HOST"),
          port: port,
          cacertfile: Path.join(tls, "ca.crt"),
          certfile: Path.join(tls, "client.crt"),
          keyfile: Path.join(tls, "client.key")
        ]
    else
      config :chat_overlay,
        custodian_listener: [
          ip: {0, 0, 0, 0},
          port: port,
          cacertfile: Path.join(tls, "ca.crt"),
          certfile: Path.join(tls, "server.crt"),
          keyfile: Path.join(tls, "server.key")
        ]
    end
  end

  port = System.get_env("CHAT_PORT", "4100") |> String.to_integer()
  if port not in 1024..65535, do: raise("Invalid CHAT_PORT")

  bind =
    case System.get_env("CHAT_BIND", "127.0.0.1") do
      "127.0.0.1" -> {127, 0, 0, 1}
      "0.0.0.0" -> {0, 0, 0, 0}
      _ -> raise "Invalid CHAT_BIND"
    end

  config :chat_overlay,
    port: port,
    bind: bind,
    trusted_proxy_ips:
      ChatOverlay.Transport.parse_proxy_ips!(System.get_env("CHAT_TRUSTED_PROXY_IPS", ""))

  config :chat_overlay,
    oauth_origin: ChatOverlay.Transport.parse_origin!(System.get_env("CHAT_PUBLIC_ORIGIN"))
end
