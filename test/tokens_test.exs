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

  test "marks account reauth_required on invalid_grant or Twitch 400 'Invalid refresh token' without crashing" do
    tokens = %{
      "access_token" => "expired_tok",
      "refresh_token" => "revoked_rt",
      "expires_in" => 10
    }

    account_data = %{username: "RevokedUser", user_id: "rev_001"}
    {:ok, _} = Profiles.link_account("streamer1", "twitch", account_data, tokens)

    # Twitch returns 400 Bad Request with message "Invalid refresh token"
    mock_http = fn :post, _url, _headers, _params ->
      {:ok, 400, %{"status" => 400, "message" => "Invalid refresh token"}}
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

  test "unlink_account/2 invalidates cache immediately and returns :not_linked" do
    tokens = %{
      "access_token" => "tok_to_unlink",
      "refresh_token" => "rt_to_unlink",
      "expires_in" => 7200
    }

    account_data = %{username: "UserToUnlink", user_id: "u_1"}
    {:ok, _} = Profiles.link_account("streamer1", "twitch", account_data, tokens)

    # Prime cache
    assert {:ok, "tok_to_unlink"} = Tokens.get_access_token("streamer1", "twitch")

    # Unlink account
    assert {:ok, _} = Profiles.unlink_account("streamer1", "twitch")

    # Tokens coordinator must immediately fail with :not_linked without serving stale cached token
    assert {:error, :not_linked} = Tokens.get_access_token("streamer1", "twitch")
  end

  test "link_account/4 invalidates cache so new credentials take effect immediately" do
    tokens_a = %{
      "access_token" => "token_identity_A",
      "refresh_token" => "rt_A",
      "expires_in" => 7200
    }

    {:ok, _} =
      Profiles.link_account(
        "streamer1",
        "twitch",
        %{username: "AccountA", user_id: "A"},
        tokens_a
      )

    assert {:ok, "token_identity_A"} = Tokens.get_access_token("streamer1", "twitch")

    # Re-link with account B
    tokens_b = %{
      "access_token" => "token_identity_B",
      "refresh_token" => "rt_B",
      "expires_in" => 7200
    }

    {:ok, _} =
      Profiles.link_account(
        "streamer1",
        "twitch",
        %{username: "AccountB", user_id: "B"},
        tokens_b
      )

    # Must immediately return token_identity_B, NOT the old token_identity_A
    assert {:ok, "token_identity_B"} = Tokens.get_access_token("streamer1", "twitch")
  end

  test "delete_profile/1 invalidates cache" do
    tokens = %{
      "access_token" => "token_before_delete",
      "refresh_token" => "rt_del",
      "expires_in" => 7200
    }

    {:ok, _} =
      Profiles.link_account(
        "streamer1",
        "twitch",
        %{username: "StreamerOne", user_id: "1"},
        tokens
      )

    assert {:ok, "token_before_delete"} = Tokens.get_access_token("streamer1", "twitch")

    # Delete profile
    assert :ok = Profiles.delete("streamer1")

    # Coordinator must return :not_found
    assert {:error, :not_found} = Tokens.get_access_token("streamer1", "twitch")
  end

  test "mark_account_reauth_required/3 invalidates cache immediately" do
    tokens = %{
      "access_token" => "token_before_revoke",
      "refresh_token" => "rt_rev",
      "expires_in" => 7200
    }

    {:ok, _} =
      Profiles.link_account(
        "streamer1",
        "twitch",
        %{username: "StreamerOne", user_id: "1"},
        tokens
      )

    assert {:ok, "token_before_revoke"} = Tokens.get_access_token("streamer1", "twitch")

    # Explicitly mark reauth_required
    assert {:ok, _} = Profiles.mark_account_reauth_required("streamer1", "twitch", :manual_revoke)

    assert {:error, :reauth_required} = Tokens.get_access_token("streamer1", "twitch")
  end

  test "race condition prevention: in-flight refresh for account A is rejected if account B is linked in between" do
    # 1. Link account A (version 1)
    tokens_a = %{
      "access_token" => "expiring_tok_A",
      "refresh_token" => "rt_A",
      "expires_in" => 10
    }

    {:ok, _} =
      Profiles.link_account(
        "streamer1",
        "twitch",
        %{username: "Identity_A", user_id: "id_A"},
        tokens_a
      )

    step_sync = :counters.new(1, [:atomics])

    # Refresh for A will hang until account B is linked
    mock_http = fn :post, _url, _headers, params ->
      if params.refresh_token == "rt_A" do
        :counters.add(step_sync, 1, 1)
        # Wait until test links account B
        Process.sleep(100)

        {:ok, 200,
         %{
           "access_token" => "refreshed_tok_for_A",
           "refresh_token" => "rt_A_rotated",
           "expires_in" => 3600
         }}
      else
        {:ok, 200,
         %{
           "access_token" => "refreshed_tok_for_B",
           "refresh_token" => "rt_B",
           "expires_in" => 3600
         }}
      end
    end

    # Launch background refresh for Account A
    task_a =
      Task.async(fn ->
        Tokens.get_access_token("streamer1", "twitch",
          http_client: mock_http,
          margin_seconds: 300
        )
      end)

    # Wait for mock to be reached
    while_counter = fn ->
      if :counters.get(step_sync, 1) == 0 do
        Process.sleep(10)
      end
    end

    while_counter.()

    # 2. While refresh for A is in-flight, link Account B (version 2)
    tokens_b = %{
      "access_token" => "fresh_tok_B",
      "refresh_token" => "rt_B",
      "expires_in" => 7200
    }

    {:ok, _} =
      Profiles.link_account(
        "streamer1",
        "twitch",
        %{username: "Identity_B", user_id: "id_B"},
        tokens_b
      )

    # 3. Wait for Task A to complete
    result_a = Task.await(task_a, 5000)

    # Task A was either aborted due to invalidation or rejected with stale_binding
    assert match?({:error, err} when err in [:binding_invalidated, :stale_binding], result_a)

    # 4. Critical verification: Profile must contain Account B's credentials!
    # Account A's refreshed token must NEVER overwrite Account B!
    assert {:ok, stored_b} = Profiles.get_linked_account_tokens("streamer1", "twitch")
    assert stored_b["access_token"] == "fresh_tok_B"
    assert stored_b["refresh_token"] == "rt_B"

    summary = Profiles.get("streamer1")
    assert summary["linked_accounts"]["twitch"]["username"] == "Identity_B"
    assert summary["linked_accounts"]["twitch"]["user_id"] == "id_B"
  end

  test "fail-closed on persistence failure during token rotation" do
    orig_path = Application.get_env(:chat_overlay, :profiles_path)

    tokens = %{
      "access_token" => "expiring_tok",
      "refresh_token" => "rt_initial",
      "expires_in" => 10
    }

    {:ok, _} =
      Profiles.link_account("streamer1", "twitch", %{username: "U1", user_id: "1"}, tokens)

    # Make profiles path unwritable to simulate disk failure
    Application.put_env(:chat_overlay, :profiles_path, "/nonexistent_disk_path/profiles.json")

    mock_http = fn :post, _url, _headers, _params ->
      {:ok, 200,
       %{
         "access_token" => "rotated_upstream_access",
         "refresh_token" => "rotated_upstream_refresh",
         "expires_in" => 3600
       }}
    end

    try do
      # Refresh attempt must fail closed with save_failed
      assert {:error, {:save_failed, {:directory_not_found, _}}} =
               Tokens.get_access_token("streamer1", "twitch", http_client: mock_http)

      # Memory state must NOT be corrupted with the unpersisted access token
      # and profile status must be marked as reauth_required
      summary = Profiles.get("streamer1")
      assert summary["linked_accounts"]["twitch"]["status"] == "reauth_required"

      assert summary["linked_accounts"]["twitch"]["last_error"] ==
               "persistence_failure_during_rotation"

      # Subsequent calls fail closed with :reauth_required
      assert {:error, :reauth_required} = Tokens.get_access_token("streamer1", "twitch")
    after
      Application.put_env(:chat_overlay, :profiles_path, orig_path)
    end
  end
end
