defmodule ChatOverlay.OAuthRefreshTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.OAuth

  setup do
    original_twitch = Application.get_env(:chat_overlay, :twitch_client_secret)
    original_yt = Application.get_env(:chat_overlay, :youtube_client_secret)

    System.put_env("TWITCH_CLIENT_ID", "test_twitch_cid")
    System.put_env("TWITCH_CLIENT_SECRET", "test_twitch_csec")
    System.put_env("YOUTUBE_CLIENT_ID", "test_yt_cid")
    System.put_env("YOUTUBE_CLIENT_SECRET", "test_yt_csec")

    on_exit(fn ->
      if original_twitch,
        do: Application.put_env(:chat_overlay, :twitch_client_secret, original_twitch),
        else: System.delete_env("TWITCH_CLIENT_SECRET")

      if original_yt,
        do: Application.put_env(:chat_overlay, :youtube_client_secret, original_yt),
        else: System.delete_env("YOUTUBE_CLIENT_SECRET")
    end)

    :ok
  end

  test "refresh_tokens/3 refreshes Twitch tokens successfully" do
    mock_http = fn :post, url, _headers, params ->
      assert url == "https://id.twitch.tv/oauth2/token"
      assert params.grant_type == "refresh_token"
      assert params.refresh_token == "initial_refresh_tok"

      {:ok, 200,
       %{
         "access_token" => "refreshed_access_tok_1",
         "refresh_token" => "rotated_refresh_tok_2",
         "expires_in" => 3600,
         "token_type" => "bearer"
       }}
    end

    assert {:ok, tokens} =
             OAuth.refresh_tokens("twitch", "initial_refresh_tok", http_client: mock_http)

    assert tokens["access_token"] == "refreshed_access_tok_1"
    assert tokens["refresh_token"] == "rotated_refresh_tok_2"
    assert tokens["expires_in"] == 3600
  end

  test "refresh_tokens/3 refreshes YouTube/Google tokens successfully when refresh_token is not returned" do
    mock_http = fn :post, url, _headers, params ->
      assert url == "https://oauth2.googleapis.com/token"
      assert params.grant_type == "refresh_token"
      assert params.refresh_token == "google_long_lived_refresh_tok"

      {:ok, 200,
       %{
         "access_token" => "new_yt_access_tok",
         "expires_in" => 3599,
         "token_type" => "Bearer"
       }}
    end

    assert {:ok, tokens} =
             OAuth.refresh_tokens("youtube", "google_long_lived_refresh_tok",
               http_client: mock_http
             )

    assert tokens["access_token"] == "new_yt_access_tok"
    assert tokens["expires_in"] == 3599
    # Note: Google omits refresh_token on refresh
    assert is_nil(tokens["refresh_token"])
  end

  test "refresh_tokens/3 handles Twitch 400 Bad Request 'Invalid refresh token' as :invalid_grant" do
    mock_http = fn :post, _url, _headers, _params ->
      {:ok, 400, %{"status" => 400, "message" => "Invalid refresh token"}}
    end

    assert {:error, :invalid_grant} =
             OAuth.refresh_tokens("twitch", "revoked_twitch_tok", http_client: mock_http)
  end

  test "refresh_tokens/3 returns {:error, :invalid_grant} on 400 invalid_grant" do
    mock_http = fn :post, _url, _headers, _params ->
      {:ok, 400,
       %{"error" => "invalid_grant", "error_description" => "Token has been expired or revoked."}}
    end

    assert {:error, :invalid_grant} =
             OAuth.refresh_tokens("twitch", "revoked_refresh_tok", http_client: mock_http)
  end

  test "refresh_tokens/3 returns {:error, :invalid_grant} on 401 unauthorized" do
    mock_http = fn :post, _url, _headers, _params ->
      {:ok, 401, %{"message" => "Invalid OAuth token"}}
    end

    assert {:error, :invalid_grant} =
             OAuth.refresh_tokens("twitch", "bad_refresh_tok", http_client: mock_http)
  end

  test "refresh_tokens/3 rejects HTTP 200 with malformed empty or invalid payload" do
    # Empty payload
    empty_mock = fn :post, _, _, _ -> {:ok, 200, %{}} end

    assert {:error, :invalid_token_payload} =
             OAuth.refresh_tokens("twitch", "tok", http_client: empty_mock)

    # Empty access_token
    blank_tok_mock = fn :post, _, _, _ ->
      {:ok, 200, %{"access_token" => "", "expires_in" => 3600}}
    end

    assert {:error, :invalid_token_payload} =
             OAuth.refresh_tokens("twitch", "tok", http_client: blank_tok_mock)

    # Invalid expires_in (<= 0 or not an int)
    invalid_exp_mock = fn :post, _, _, _ ->
      {:ok, 200, %{"access_token" => "valid_tok", "expires_in" => 0}}
    end

    assert {:error, :invalid_token_payload} =
             OAuth.refresh_tokens("twitch", "tok", http_client: invalid_exp_mock)
  end

  test "refresh_tokens/3 parses string expires_in correctly and accepts raw JSON bodies" do
    json_mock = fn :post, _, _, _ ->
      {:ok, 200, ~s({"access_token": "tok_from_json", "expires_in": "1800"})}
    end

    assert {:ok, tokens} =
             OAuth.refresh_tokens("twitch", "tok", http_client: json_mock)

    assert tokens["access_token"] == "tok_from_json"
    assert tokens["expires_in"] == 1800
  end

  test "refresh_tokens/3 surfaces upstream auth errors safely" do
    mock_http = fn :post, _url, _headers, _params ->
      {:ok, 400, %{"error" => "unauthorized_client"}}
    end

    assert {:error, {:upstream_auth_error, "unauthorized_client"}} =
             OAuth.refresh_tokens("twitch", "some_tok", http_client: mock_http)
  end

  test "refresh_tokens/3 fails with unconfigured client credentials if env missing" do
    orig_cid = Application.get_env(:chat_overlay, :twitch_client_id)
    Application.put_env(:chat_overlay, :twitch_client_id, nil)
    System.delete_env("TWITCH_CLIENT_ID")

    try do
      assert {:error, {:unconfigured_client, "twitch"}} =
               OAuth.refresh_tokens("twitch", "some_tok")
    after
      Application.put_env(:chat_overlay, :twitch_client_id, orig_cid)
    end
  end
end
