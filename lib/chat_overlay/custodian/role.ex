defmodule ChatOverlay.Custodian.Role do
  @moduledoc "Explicit process roles. The public role refuses private credential configuration."
  @private_env ~w(CHAT_ENCRYPTION_KEY CHAT_DB_RUNTIME_PASSWORD CHAT_DB_BOOTSTRAP_PASSWORD
    TWITCH_CLIENT_SECRET GOOGLE_CLIENT_SECRET YOUTUBE_CLIENT_SECRET MEDIA_COORDINATOR_TOKEN
    R2_SECRET_ACCESS_KEY R2_QUARANTINE_SECRET_ACCESS_KEY R2_ACCESS_KEY_ID
    R2_QUARANTINE_ACCESS_KEY_ID CHAT_TWITCH_TOKEN CHAT_YOUTUBE_TOKEN CHAT_KICK_TOKEN CHAT_CONFIG)
  @private_config ~w(encryption_key postgres_runtime postgres_bootstrap twitch_client_secret
    google_client_secret youtube_client_secret media_coordinator_token r2_secret_access_key
    r2_quarantine_secret_access_key r2_access_key_id r2_quarantine_access_key_id)a

  def parse!(nil), do: :combined
  def parse!("frontend"), do: :frontend
  def parse!("custodian"), do: :custodian
  def parse!("combined"), do: :combined
  def parse!(_), do: raise(ArgumentError, "CHAT_ROLE must be frontend, custodian or combined")
  def current, do: Application.get_env(:chat_overlay, :role, :combined)

  def assert_safe_frontend!(
        env \\ System.get_env(),
        config \\ Application.get_all_env(:chat_overlay)
      ) do
    if Enum.any?(@private_env, &Map.has_key?(env, &1)) or
         Enum.any?(@private_config, &(Keyword.get(config, &1) != nil)) or
         Keyword.get(config, :profiles, []) != [] or Keyword.get(config, :media_objects, []) != [] do
      raise ArgumentError, "Frontend cannot start with private credentials or profile state"
    end

    :ok
  end
end
