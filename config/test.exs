import Config
config :chat_overlay, http: false, env: :test

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

config :chat_overlay,
  r2_endpoint: "https://r2.example.com",
  r2_bucket: "chat-overlay-media",
  r2_access_key_id: "mock_access_key",
  r2_secret_access_key: "mock_secret_key",
  r2_public_cdn: "https://media.chat-overlay.example.com"

config :chat_overlay,
  r2_quarantine_bucket: "chat-overlay-quarantine",
  r2_quarantine_access_key_id: "synthetic-private-key",
  r2_quarantine_secret_access_key: "synthetic-private-secret",
  media_coordinator_token: String.duplicate("t", 43)
