import Config

if config_env() != :test do
  if path = System.get_env("CHAT_CONFIG") do
    document = ChatOverlay.Config.load_document!(path)
    config :chat_overlay, profiles: document["profiles"], media_objects: document["media_objects"]
  end

  port = System.get_env("CHAT_PORT", "4100") |> String.to_integer()
  if port not in 1024..65535, do: raise("Invalid CHAT_PORT")

  bind =
    case System.get_env("CHAT_BIND", "127.0.0.1") do
      "127.0.0.1" -> {127, 0, 0, 1}
      "0.0.0.0" -> {0, 0, 0, 0}
      _ -> raise "Invalid CHAT_BIND"
    end

  config :chat_overlay, port: port, bind: bind
end
