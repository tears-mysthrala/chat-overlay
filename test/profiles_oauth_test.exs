defmodule ChatOverlay.ProfilesOAuthTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Config, Profiles}

  setup do
    original_profiles = Application.get_env(:chat_overlay, :profiles, [])

    on_exit(fn ->
      Application.put_env(:chat_overlay, :profiles, original_profiles)
    end)

    test_profile = %{
      "handle" => "creator1",
      "sources" => [
        %{"platform" => "twitch", "channel" => "creator1", "mode" => "demo"}
      ]
    }

    Application.put_env(:chat_overlay, :profiles, [test_profile])
    :ok
  end

  test "link_account/4 stores encrypted tokens and exposes sanitized metadata" do
    account_data = %{
      username: "CreatorTwitch",
      user_id: "998877"
    }

    tokens = %{
      "access_token" => "secret_access_token_123",
      "refresh_token" => "secret_refresh_token_456",
      "expires_in" => 7200
    }

    assert {:ok, _updated} = Profiles.link_account("creator1", "twitch", account_data, tokens)

    # Profiles.get and Profiles.list must sanitize encrypted_tokens (SEC-10)
    profile_summary = Profiles.get("creator1")
    assert profile_summary["linked_accounts"]["twitch"]["linked"] == true
    assert profile_summary["linked_accounts"]["twitch"]["username"] == "CreatorTwitch"
    assert profile_summary["linked_accounts"]["twitch"]["user_id"] == "998877"
    refute Map.has_key?(profile_summary["linked_accounts"]["twitch"], "encrypted_tokens")

    # Raw profile in config has encrypted_tokens
    raw_profile = Config.profile("creator1")
    raw_twitch = raw_profile["linked_accounts"]["twitch"]
    assert String.starts_with?(raw_twitch["encrypted_tokens"], "v1:")

    # Authorized internal helper can decrypt tokens
    assert {:ok, decrypted_tokens} = Profiles.get_linked_account_tokens("creator1", "twitch")
    assert decrypted_tokens["access_token"] == "secret_access_token_123"
    assert decrypted_tokens["refresh_token"] == "secret_refresh_token_456"
  end

  test "unlink_account/2 removes stored credentials" do
    account_data = %{username: "YTUser", user_id: "112233"}
    tokens = %{"access_token" => "tok_abc"}

    {:ok, _} = Profiles.link_account("creator1", "youtube", account_data, tokens)
    assert Profiles.get("creator1")["linked_accounts"]["youtube"]["linked"] == true

    assert {:ok, _} = Profiles.unlink_account("creator1", "youtube")
    profile_summary = Profiles.get("creator1")
    refute Map.has_key?(profile_summary["linked_accounts"], "youtube")

    assert {:error, :not_linked} = Profiles.get_linked_account_tokens("creator1", "youtube")
  end

  test "link_account/4 fails and surfaces error when persistence storage path is unwritable" do
    orig_path = Application.get_env(:chat_overlay, :profiles_path)
    # Set to an unwritable directory
    Application.put_env(:chat_overlay, :profiles_path, "/nonexistent_root_dir/profiles.json")

    account_data = %{username: "UnwritableUser", user_id: "999"}
    tokens = %{"access_token" => "tok_xyz"}

    try do
      assert {:error, {:directory_not_found, "/nonexistent_root_dir"}} =
               Profiles.link_account("creator1", "twitch", account_data, tokens)
    after
      if orig_path do
        Application.put_env(:chat_overlay, :profiles_path, orig_path)
      else
        Application.delete_env(:chat_overlay, :profiles_path)
      end
    end
  end
end
