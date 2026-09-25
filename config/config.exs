import Config

config :chat_overlay, http: true, port: 4100, bind: {127, 0, 0, 1}, profiles: []
config :logger, level: :warning
import_config "#{config_env()}.exs"
