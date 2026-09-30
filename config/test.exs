import Config
config :chat_overlay, http: false

config :chat_overlay,
  grace_ms: 30,
  profiles: [
    %{
      "handle" => "test",
      "sources" => [
        %{"platform" => "twitch", "channel" => "test-channel", "mode" => "demo"},
        %{"platform" => "kick", "channel" => "test-kick", "mode" => "demo"}
      ]
    },
    %{
      "handle" => "other",
      "sources" => [%{"platform" => "youtube", "channel" => "other-channel", "mode" => "demo"}]
    }
  ],
  twitch_client_id: "test_twitch_client_id",
  twitch_client_secret: "test_twitch_client_secret",
  google_client_id: "test_google_client_id",
  google_client_secret: "test_google_client_secret"
