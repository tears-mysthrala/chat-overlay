defmodule ChatOverlay.TokensTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Config, Profiles, Tokens}

  setup do
    original_profiles = Application.get_env(:chat_overlay, :profiles, [])

    # Set up client credentials
    System.put_env("TWITCH_CLIENT_ID", "test_twitch_cid")
    System.put_env("TWITCH_CLIENT_SECRET", "test_twitch_csec")
    System.put_env("YOUTUBE_CLIENT_ID", "test_yt_cid")
    System.put_env("YOUTUBE_CLIENT_SECRET", "test_yt_csec")

    Tokens.clear()

    on_exit(fn ->
      Tokens.clear()
      Application.put_env(:chat_overlay, :profiles, original_profiles)
      System.delete_env("TWITCH_CLIENT_ID")
      System.delete_env("TWITCH_CLIENT_SECRET")
      System.delete_env("YOUTUBE_CLIENT_ID")
      System.delete_env("YOUTUBE_CLIENT_SECRET")
    end)

    test_profile = %{
      "handle" => "streamer1",
      "sources" => [
        %{"platform" => "twitch", "channel" => "streamer1", "mode" => "demo"}
      ]
    }

    Application.put_env(:chat_overlay, :profiles, [test_profile])
    :ok
  end

  test "returns cached token without hitting upstream if token is fresh" do
    # Link account with token valid for 2 hours
    tokens = %{
      "access_token" => "fresh_access_token_123",
      "refresh_token" => "valid_refresh_token_456",
      "expires_in" => 7200
    }

    account_data = %{username: "StreamerOne", user_id: "12345"}
    {:ok, _} = Profiles.link_account("streamer1", "twitch", account_data, tokens)

    # Should not call upstream http_client
    mock_http = fn _, _, _, _ ->
      flunk("Upstream HTTP called unexpectedly for fresh token!")
    end

    assert {:ok, "fresh_access_token_123"} =
             Tokens.get_access_token("streamer1", "twitch", http_client: mock_http)

    # Calling again uses in-memory cache
    assert {:ok, "fresh_access_token_123"} =
             Tokens.get_access_token("streamer1", "twitch", http_client: mock_http)
  end

  test "proactively renews token if within margin_seconds of expiration" do
    # Link account with token expiring in 100 seconds (below default 300s margin)
    tokens = %{
      "access_token" => "expiring_soon_access_token",
      "refresh_token" => "refresh_token_abc",
      "expires_in" => 100
    }

    account_data = %{username: "StreamerOne", user_id: "12345"}
    {:ok, _} = Profiles.link_account("streamer1", "twitch", account_data, tokens)

    called_ref = :counters.new(1, [:atomics])

    mock_http = fn :post, _url, _headers, params ->
      :counters.add(called_ref, 1, 1)
      assert params.refresh_token == "refresh_token_abc"

      {:ok, 200,
       %{
         "access_token" => "newly_refreshed_access_token",
         "refresh_token" => "refresh_token_rotated",
         "expires_in" => 3600
       }}
    end

    assert {:ok, "newly_refreshed_access_token"} =
             Tokens.get_access_token("streamer1", "twitch", http_client: mock_http)

    assert :counters.get(called_ref, 1) == 1

    # Second call uses new cached token
    assert {:ok, "newly_refreshed_access_token"} =
             Tokens.get_access_token("streamer1", "twitch")

    assert :counters.get(called_ref, 1) == 1
  end

  test "stampede protection: 10 concurrent requests result in exactly 1 upstream call" do
    # Link account with expired token
    tokens = %{
      "access_token" => "expired_token",
      "refresh_token" => "valid_rt",
      "expires_in" => 10
    }

    account_data = %{username: "StreamerOne", user_id: "12345"}
    {:ok, _} = Profiles.link_account("streamer1", "twitch", account_data, tokens)

    called_ref = :counters.new(1, [:atomics])

    mock_http = fn :post, _url, _headers, _params ->
      :counters.add(called_ref, 1, 1)
      # Simulate realistic network latency to allow concurrency overlap
      Process.sleep(80)

      {:ok, 200,
       %{
         "access_token" => "coalesced_access_token_999",
         "refresh_token" => "valid_rt",
         "expires_in" => 3600
       }}
    end

    # Spawn 10 concurrent tasks calling Tokens.get_access_token simultaneously
    tasks =
      for _i <- 1..10 do
        Task.async(fn ->
          Tokens.get_access_token("streamer1", "twitch",
            http_client: mock_http,
            margin_seconds: 300
          )
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5000))

    # All 10 tasks must receive the identical refreshed access token
    Enum.each(results, fn res ->
      assert {:ok, "coalesced_access_token_999"} = res
    end)

    # Exactly 1 upstream call must have occurred (SEC-15 stampede protection)
    assert :counters.get(called_ref, 1) == 1
  end

  test "preserves existing refresh_token when upstream omits it (Google/YouTube)" do
    # Link account with Google refresh_token
    tokens = %{
      "access_token" => "initial_yt_access",
      "refresh_token" => "secret_google_refresh_token_to_preserve",
      "expires_in" => 50
    }

    account_data = %{username: "YTStreamer", user_id: "yt_001"}
    {:ok, _} = Profiles.link_account("streamer1", "youtube", account_data, tokens)

    mock_http = fn :post, _url, _headers, params ->
      assert params.refresh_token == "secret_google_refresh_token_to_preserve"

      # Google returns access_token without refresh_token
      {:ok, 200,
       %{
         "access_token" => "fresh_google_access_token",
         "expires_in" => 3600
       }}
    end

    assert {:ok, "fresh_google_access_token"} =
             Tokens.get_access_token("streamer1", "youtube", http_client: mock_http)

    # Verify that the profile still has the preserved refresh_token in storage
    assert {:ok, stored_tokens} = Profiles.get_linked_account_tokens("streamer1", "youtube")
    assert stored_tokens["access_token"] == "fresh_google_access_token"
    assert stored_tokens["refresh_token"] == "secret_google_refresh_token_to_preserve"

    # Profile in config must be encrypted at rest with v1:...
    raw = Config.profile("streamer1")
    assert String.starts_with?(raw["linked_accounts"]["youtube"]["encrypted_tokens"], "v1:")
  end

  test "handles token rotation when upstream provides a new refresh_token" do
    tokens = %{
      "access_token" => "old_access",
      "refresh_token" => "rt_gen_1",
      "expires_in" => 50
    }

    account_data = %{username: "TwitchUser", user_id: "tw_001"}
    {:ok, _} = Profiles.link_account("streamer1", "twitch", account_data, tokens)

    mock_http = fn :post, _url, _headers, _params ->
      {:ok, 200,
       %{
         "access_token" => "new_access_2",
         "refresh_token" => "rt_gen_2_rotated",
         "expires_in" => 3600
       }}
    end

    assert {:ok, "new_access_2"} =
             Tokens.get_access_token("streamer1", "twitch", http_client: mock_http)

    # Rotated refresh_token must be stored
    assert {:ok, stored_tokens} = Profiles.get_linked_account_tokens("streamer1", "twitch")
    assert stored_tokens["access_token"] == "new_access_2"
    assert stored_tokens["refresh_token"] == "rt_gen_2_rotated"
  end

  test "marks account reauth_required on invalid_grant without crashing" do
    tokens = %{
      "access_token" => "expired_tok",
      "refresh_token" => "revoked_rt",
      "expires_in" => 10
    }

    account_data = %{username: "RevokedUser", user_id: "rev_001"}
    {:ok, _} = Profiles.link_account("streamer1", "twitch", account_data, tokens)

    mock_http = fn :post, _url, _headers, _params ->
      {:ok, 400, %{"error" => "invalid_grant"}}
    end

    assert {:error, :reauth_required} =
             Tokens.get_access_token("streamer1", "twitch", http_client: mock_http)

    # Profile summary must reflect reauth_required status
    summary = Profiles.get("streamer1")
    assert summary["linked_accounts"]["twitch"]["status"] == "reauth_required"
    assert summary["linked_accounts"]["twitch"]["last_error"] == "invalid_grant"

    # Subsequent calls immediately return {:error, :reauth_required} without network call
    assert {:error, :reauth_required} = Tokens.get_access_token("streamer1", "twitch")
  end

  test "invalidate/2 forces token refresh on next call" do
    tokens = %{
      "access_token" => "initial_token",
      "refresh_token" => "my_rt",
      "expires_in" => 7200
    }

    account_data = %{username: "User", user_id: "1"}
    {:ok, _} = Profiles.link_account("streamer1", "twitch", account_data, tokens)

    assert {:ok, "initial_token"} = Tokens.get_access_token("streamer1", "twitch")

    # Invalidate cache
    :ok = Tokens.invalidate("streamer1", "twitch")

    # Force refresh or expired will hit upstream
    mock_http = fn :post, _url, _headers, _params ->
      {:ok, 200, %{"access_token" => "refreshed_after_invalidate", "expires_in" => 3600}}
    end

    assert {:ok, "refreshed_after_invalidate"} =
             Tokens.get_access_token("streamer1", "twitch",
               force_refresh: true,
               http_client: mock_http
             )
  end
end
