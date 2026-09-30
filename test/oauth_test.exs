defmodule ChatOverlay.OAuthTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.OAuth

  setup do
    Application.put_env(:chat_overlay, :twitch_client_id, "mock_twitch_id")
    Application.put_env(:chat_overlay, :twitch_client_secret, "mock_twitch_secret")
    Application.put_env(:chat_overlay, :google_client_id, "mock_google_id")
    Application.put_env(:chat_overlay, :google_client_secret, "mock_google_secret")
    :ok
  end

  describe "authorize_url/4" do
    test "generates valid Twitch authorization URL with PKCE and encrypted state" do
      redirect_uri = "https://example.com/oauth/callback/twitch"
      {:ok, url} = OAuth.authorize_url("twitch", "streamer1", redirect_uri)

      uri = URI.parse(url)
      assert uri.scheme == "https"
      assert uri.host == "id.twitch.tv"
      assert uri.path == "/oauth2/authorize"

      query = URI.decode_query(uri.query)
      assert query["client_id"] == "mock_twitch_id"
      assert query["redirect_uri"] == redirect_uri
      assert query["response_type"] == "code"
      assert query["code_challenge_method"] == "S256"
      assert is_binary(query["code_challenge"]) and byte_size(query["code_challenge"]) > 20
      assert is_binary(query["state"]) and String.starts_with?(query["state"], "v1:")

      # Verify the state decrypts and contains handle and verifier
      {:ok, state_data} = OAuth.verify_state(query["state"])
      assert state_data["handle"] == "streamer1"
      assert state_data["provider"] == "twitch"
      assert is_binary(state_data["verifier"])
    end

    test "generates valid YouTube / Google authorization URL with PKCE and offline access" do
      redirect_uri = "https://example.com/oauth/callback/youtube"
      {:ok, url} = OAuth.authorize_url("youtube", "streamer2", redirect_uri)

      uri = URI.parse(url)
      assert uri.scheme == "https"
      assert uri.host == "accounts.google.com"
      assert uri.path == "/o/oauth2/v2/auth"

      query = URI.decode_query(uri.query)
      assert query["client_id"] == "mock_google_id"
      assert query["redirect_uri"] == redirect_uri
      assert query["response_type"] == "code"
      assert query["access_type"] == "offline"
      assert query["prompt"] == "consent"
      assert query["code_challenge_method"] == "S256"

      {:ok, state_data} = OAuth.verify_state(query["state"])
      assert state_data["handle"] == "streamer2"
      assert state_data["provider"] == "youtube"
      assert is_binary(state_data["verifier"])
    end

    test "rejects unsupported provider" do
      assert {:error, :unsupported_provider} =
               OAuth.authorize_url("facebook", "streamer", "https://example.com/callback")
    end

    test "rejects unconfigured client ID" do
      Application.delete_env(:chat_overlay, :twitch_client_id)
      System.delete_env("TWITCH_CLIENT_ID")

      assert {:error, {:unconfigured_client, "twitch"}} =
               OAuth.authorize_url("twitch", "streamer", "https://example.com/callback")

      # Restore
      Application.put_env(:chat_overlay, :twitch_client_id, "mock_twitch_id")
    end
  end

  describe "verify_state/2" do
    test "verifies fresh state successfully" do
      state = OAuth.generate_state("user1", "twitch", "test_verifier")
      assert {:ok, data} = OAuth.verify_state(state)
      assert data["handle"] == "user1"
      assert data["provider"] == "twitch"
      assert data["verifier"] == "test_verifier"
    end

    test "rejects expired state" do
      # Generate state with timestamp 700 seconds in the past
      past_ts = System.system_time(:second) - 700

      payload = %{
        "handle" => "user1",
        "provider" => "twitch",
        "verifier" => "test_verifier",
        "ts" => past_ts,
        "nonce" => "123"
      }

      {:ok, state} =
        ChatOverlay.Crypto.encrypt_aead(
          ChatOverlay.JSON.encode(payload),
          OAuth.encryption_key(),
          "oauth_state"
        )

      assert {:error, :expired} = OAuth.verify_state(state, 600)
    end

    test "rejects tampered or malformed state" do
      assert {:error, :invalid_state} = OAuth.verify_state("invalid_state_string")
      assert {:error, :invalid_state} = OAuth.verify_state("v1:corrupted_bytes")
    end
  end

  describe "handle_callback/5 with mock client" do
    test "successfully exchanges code for Twitch tokens and user info" do
      state = OAuth.generate_state("streamer", "twitch", "pkce_verifier_123")

      mock_client = fn
        # Token exchange
        :post, "https://id.twitch.tv/oauth2/token", _headers, _body ->
          {:ok, 200,
           %{
             "access_token" => "mock_twitch_access_token",
             "refresh_token" => "mock_twitch_refresh_token",
             "expires_in" => 3600,
             "token_type" => "bearer"
           }}

        # User profile
        :get, "https://api.twitch.tv/helix/users", _headers, _body ->
          {:ok, 200,
           %{
             "data" => [
               %{
                 "id" => "123456",
                 "login" => "streamer_twitch",
                 "display_name" => "StreamerLive"
               }
             ]
           }}
      end

      assert {:ok, result} =
               OAuth.handle_callback(
                 "twitch",
                 "mock_auth_code",
                 state,
                 "https://example.com/oauth/callback/twitch",
                 http_client: mock_client
               )

      assert result.handle == "streamer"
      assert result.provider == "twitch"
      assert result.username == "StreamerLive"
      assert result.user_id == "123456"
      assert is_map(result.tokens)
      assert result.tokens["access_token"] == "mock_twitch_access_token"
    end

    test "handles upstream OAuth errors" do
      state = OAuth.generate_state("streamer", "twitch", "pkce_verifier_123")

      assert {:error, :upstream_error, "access_denied"} =
               OAuth.handle_callback(
                 "twitch",
                 nil,
                 state,
                 "https://example.com/oauth/callback/twitch",
                 error: "access_denied"
               )
    end

    test "handles token exchange failure gracefully" do
      state = OAuth.generate_state("streamer", "twitch", "pkce_verifier_123")

      mock_failing_client = fn
        :post, "https://id.twitch.tv/oauth2/token", _headers, _body ->
          {:ok, 400, %{"message" => "Invalid authorization code"}}
      end

      assert {:error, :token_exchange_failed} =
               OAuth.handle_callback(
                 "twitch",
                 "bad_code",
                 state,
                 "https://example.com/oauth/callback/twitch",
                 http_client: mock_failing_client
               )
    end
  end

  describe "validate_encryption_key/1" do
    test "allows default key or no key in non-production environments" do
      assert :ok = OAuth.validate_encryption_key(env: :test, key: nil)

      assert :ok =
               OAuth.validate_encryption_key(
                 env: :dev,
                 key: "chat_overlay_secret_key_32_bytes!"
               )
    end

    test "rejects short key in non-production environments" do
      assert {:error, :encryption_key_too_short} =
               OAuth.validate_encryption_key(env: :test, key: "short_key")
    end

    test "requires explicit key in production" do
      assert {:error, :missing_production_encryption_key} =
               OAuth.validate_encryption_key(env: :prod, key: nil)

      assert {:error, :missing_production_encryption_key} =
               OAuth.validate_encryption_key(env: :prod, key: "")

      assert {:error, :missing_production_encryption_key} =
               OAuth.validate_encryption_key(env: :prod, key: 12345)

      assert {:error, :missing_production_encryption_key} =
               OAuth.validate_encryption_key(env: :prod, key: :not_a_binary)
    end

    test "rejects default development key in production" do
      assert {:error, :missing_production_encryption_key} =
               OAuth.validate_encryption_key(
                 env: :prod,
                 key: "chat_overlay_secret_key_32_bytes!"
               )
    end

    test "enforces production validation when release is active" do
      assert {:error, :missing_production_encryption_key} =
               OAuth.validate_encryption_key(
                 release: true,
                 key: "chat_overlay_secret_key_32_bytes!"
               )
    end

    test "rejects key shorter than 32 bytes in production" do
      assert {:error, :encryption_key_too_short} =
               OAuth.validate_encryption_key(env: :prod, key: "only_24_bytes_key_here!")
    end

    test "accepts valid 32-byte key in production" do
      assert :ok =
               OAuth.validate_encryption_key(
                 env: :prod,
                 key: "production_secret_key_32_bytes_ok!"
               )
    end
  end
end
