defmodule ChatOverlay.WebSessionAuthTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{JSON, OAuth, Session}

  setup_all do
    Application.put_env(:chat_overlay, :port, 0)
    start_supervised!(ChatOverlay.HTTP)
    %{port: ChatOverlay.HTTP.port()}
  end

  setup do
    original_profiles = Application.get_env(:chat_overlay, :profiles, [])
    original_client = Application.get_env(:chat_overlay, :oauth_http_client)

    System.put_env("CHAT_TWITCH_TOKEN", "mock_token")

    on_exit(fn ->
      Application.put_env(:chat_overlay, :profiles, original_profiles)

      if original_client do
        Application.put_env(:chat_overlay, :oauth_http_client, original_client)
      else
        Application.delete_env(:chat_overlay, :oauth_http_client)
      end
    end)

    p1 = %{
      "handle" => "streamer",
      "sources" => [
        %{"platform" => "twitch", "channel" => "streamer", "mode" => "demo"}
      ],
      "can_upload" => true,
      "storage_quota_bytes" => 10_485_760,
      "storage_used_bytes" => 0
    }

    p2 = %{
      "handle" => "streamer2",
      "sources" => [
        %{"platform" => "twitch", "channel" => "streamer2", "mode" => "demo"}
      ],
      "can_upload" => true,
      "storage_quota_bytes" => 10_485_760,
      "storage_used_bytes" => 0
    }

    p_prod = %{
      "handle" => "streamer-prod",
      "sources" => [
        %{
          "platform" => "twitch",
          "channel" => "12345",
          "user_id" => "12345",
          "client_id" => "mock_client",
          "credential_env" => "CHAT_TWITCH_TOKEN"
        }
      ],
      "can_upload" => true,
      "storage_quota_bytes" => 10_485_760,
      "storage_used_bytes" => 0
    }

    Application.put_env(:chat_overlay, :profiles, [p1, p2, p_prod])
    :ok
  end

  defp connection(port) do
    {:ok, conn} =
      ChatOverlay.TestClient.open(~c"localhost", port, %{retry: 0, protocols: [:http]})

    {:ok, :http} = ChatOverlay.TestClient.await_up(conn)
    conn
  end

  defp request(port, method, path, headers \\ [], body \\ "") do
    conn = connection(port)

    try do
      ref = ChatOverlay.TestClient.request(conn, method, path, headers, body)
      {:response, fin, status, headers} = ChatOverlay.TestClient.await(conn, ref)
      body = if fin == :nofin, do: elem(ChatOverlay.TestClient.await_body(conn, ref), 1), else: ""
      {status, headers, body}
    after
      ChatOverlay.TestClient.close(conn)
    end
  end

  defp session_cookie_header(handle) do
    {:ok, token} = Session.create_token(%{"handle" => handle, "provider" => "twitch"})
    {"cookie", "#{Session.cookie_name()}=#{token}"}
  end

  test "GET /api/auth/me returns unauthenticated status without session", %{port: port} do
    {200, headers, body} = request(port, "GET", "/api/auth/me")
    assert Enum.any?(headers, fn {k, v} -> k == "content-type" and v =~ "application/json" end)

    assert {:ok, data} = JSON.decode(body)
    assert data["ok"] == true
    assert data["authenticated"] == false
  end

  test "GET /api/auth/me and GET /api/session reflect active creator session", %{port: port} do
    cookie = session_cookie_header("streamer")

    {200, _, body} = request(port, "GET", "/api/auth/me", [cookie])
    assert {:ok, data} = JSON.decode(body)
    assert data["ok"] == true
    assert data["authenticated"] == true
    assert data["handle"] == "streamer"
    assert data["provider"] == "twitch"
    assert is_integer(data["expires_at"])

    # Alias /api/session
    {200, _, body2} = request(port, "GET", "/api/session", [cookie])
    assert {:ok, data2} = JSON.decode(body2)
    assert data2["authenticated"] == true
    assert data2["handle"] == "streamer"
  end

  test "POST /api/auth/logout invalidates session cookie", %{port: port} do
    cookie = session_cookie_header("streamer")
    origin = {"origin", "http://localhost:#{port}"}

    # Reject bad origin (CSRF)
    bad_origin = {"origin", "https://malicious.evil.com"}
    {403, _, _} = request(port, "POST", "/api/auth/logout", [cookie, bad_origin])

    # Allow valid origin
    {200, headers, body} = request(port, "POST", "/api/auth/logout", [cookie, origin])
    assert {:ok, data} = JSON.decode(body)
    assert data["ok"] == true

    # Verify Set-Cookie header contains max-age=0
    set_cookies =
      headers
      |> Enum.filter(fn {k, _} -> k == "set-cookie" end)
      |> Enum.map(&elem(&1, 1))

    assert Enum.any?(set_cookies, fn c ->
             c =~ "#{Session.cookie_name()}=" and c =~ "max-age=0"
           end)
  end

  test "GET /api/profiles isolates profiles to current session handle (SEC-12, SEC-14)", %{
    port: port
  } do
    cookie1 = session_cookie_header("streamer")
    {200, _, body1} = request(port, "GET", "/api/profiles", [cookie1])
    assert {:ok, data1} = JSON.decode(body1)
    handles1 = Enum.map(data1["profiles"], & &1["handle"])
    assert handles1 == ["streamer"]

    cookie2 = session_cookie_header("streamer2")
    {200, _, body2} = request(port, "GET", "/api/profiles", [cookie2])
    assert {:ok, data2} = JSON.decode(body2)
    handles2 = Enum.map(data2["profiles"], & &1["handle"])
    assert handles2 == ["streamer2"]
  end

  test "POST /api/profiles/:handle/token/regenerate enforces strict profile authorization", %{
    port: port
  } do
    origin = {"origin", "http://localhost:#{port}"}
    content_type = {"content-type", "application/json"}
    cookie_streamer = session_cookie_header("streamer")

    # 1. Matching session -> 200 OK
    {200, _, body} =
      request(
        port,
        "POST",
        "/api/profiles/streamer/token/regenerate",
        [origin, content_type, cookie_streamer],
        "{}"
      )

    assert {:ok, data} = JSON.decode(body)
    assert data["ok"] == true
    assert is_binary(data["token"])

    # 2. Cross-profile tampering (streamer accessing streamer2) -> 403 Forbidden
    {403, _, forbidden_body} =
      request(
        port,
        "POST",
        "/api/profiles/streamer2/token/regenerate",
        [origin, content_type, cookie_streamer],
        "{}"
      )

    assert {:ok, forbidden_data} = JSON.decode(forbidden_body)
    assert forbidden_data["ok"] == false
    assert forbidden_data["error"] =~ "Acceso no autorizado"

    # 3. Non-demo production profile without session -> 401 Unauthorized
    {401, _, unauth_body} =
      request(
        port,
        "POST",
        "/api/profiles/streamer-prod/token/regenerate",
        [origin, content_type],
        "{}"
      )

    assert {:ok, unauth_data} = JSON.decode(unauth_body)
    assert unauth_data["ok"] == false
    assert unauth_data["error"] =~ "No autorizado"
  end

  test "POST /api/profiles/:handle/media enforces strict profile authorization", %{
    port: port
  } do
    origin = {"origin", "http://localhost:#{port}"}
    content_type = {"content-type", "application/json"}
    cookie_streamer = session_cookie_header("streamer")

    payload =
      JSON.encode(%{
        "alert_sound" => %{"url" => "https://8.8.8.8/alerts/sound.mp3", "source" => "external"}
      })

    # 1. Matching session -> 200 OK
    {200, _, body} =
      request(
        port,
        "POST",
        "/api/profiles/streamer/media",
        [origin, content_type, cookie_streamer],
        payload
      )

    assert {:ok, data} = JSON.decode(body)
    assert data["ok"] == true

    # 2. Cross-profile tampering -> 403 Forbidden
    {403, _, forbidden_body} =
      request(
        port,
        "POST",
        "/api/profiles/streamer2/media",
        [origin, content_type, cookie_streamer],
        payload
      )

    assert {:ok, forbidden_data} = JSON.decode(forbidden_body)
    assert forbidden_data["ok"] == false
    assert forbidden_data["error"] =~ "Acceso no autorizado"

    # 3. Non-demo production profile without session -> 401 Unauthorized
    {401, _, unauth_body} =
      request(
        port,
        "POST",
        "/api/profiles/streamer-prod/media",
        [origin, content_type],
        payload
      )

    assert {:ok, unauth_data} = JSON.decode(unauth_body)
    assert unauth_data["ok"] == false
  end

  test "POST /api/media/presign enforces strict profile authorization", %{
    port: port
  } do
    origin = {"origin", "http://localhost:#{port}"}
    content_type = {"content-type", "application/json"}
    cookie_streamer = session_cookie_header("streamer")

    streamer_payload =
      JSON.encode(%{
        "handle" => "streamer",
        "filename" => "alert.mp3",
        "content_type" => "audio/mpeg",
        "size" => 1024 * 100
      })

    streamer2_payload =
      JSON.encode(%{
        "handle" => "streamer2",
        "filename" => "alert.mp3",
        "content_type" => "audio/mpeg",
        "size" => 1024 * 100
      })

    prod_payload =
      JSON.encode(%{
        "handle" => "streamer-prod",
        "filename" => "alert.mp3",
        "content_type" => "audio/mpeg",
        "size" => 1024 * 100
      })

    # 1. Matching session -> 200 OK
    {200, _, body} =
      request(
        port,
        "POST",
        "/api/media/presign",
        [origin, content_type, cookie_streamer],
        streamer_payload
      )

    assert {:ok, data} = JSON.decode(body)
    assert data["ok"] == true

    # 2. Cross-profile tampering (streamer requesting presign for streamer2) -> 403 Forbidden
    {403, _, forbidden_body} =
      request(
        port,
        "POST",
        "/api/media/presign",
        [origin, content_type, cookie_streamer],
        streamer2_payload
      )

    assert {:ok, forbidden_data} = JSON.decode(forbidden_body)
    assert forbidden_data["ok"] == false

    # 3. Non-demo production profile without session -> 401 Unauthorized
    {401, _, unauth_body} =
      request(
        port,
        "POST",
        "/api/media/presign",
        [origin, content_type],
        prod_payload
      )

    assert {:ok, unauth_data} = JSON.decode(unauth_body)
    assert unauth_data["ok"] == false
  end

  test "DELETE /api/profiles/:handle rejects unauthorized deletion", %{port: port} do
    origin = {"origin", "http://localhost:#{port}"}
    cookie_streamer = session_cookie_header("streamer")

    # streamer trying to delete streamer2 -> 403 Forbidden
    {403, _, forbidden_body} =
      request(port, "DELETE", "/api/profiles/streamer2", [origin, cookie_streamer])

    assert {:ok, forbidden_data} = JSON.decode(forbidden_body)
    assert forbidden_data["ok"] == false

    # Unauthenticated deleting production non-demo profile -> 401 Unauthorized
    {401, _, unauth_body} = request(port, "DELETE", "/api/profiles/streamer-prod", [origin])
    assert {:ok, unauth_data} = JSON.decode(unauth_body)
    assert unauth_data["ok"] == false
  end

  test "OAuth callback issues encrypted HttpOnly SameSite=Lax session cookie on success", %{
    port: port
  } do
    # Configure mock OAuth client
    mock_client = fn
      :post, "https://id.twitch.tv/oauth2/token", _headers, _body ->
        {:ok, 200,
         %{
           "access_token" => "mock_twitch_token_123",
           "refresh_token" => "mock_twitch_refresh_123",
           "expires_in" => 3600,
           "token_type" => "bearer"
         }}

      :get, "https://api.twitch.tv/helix/users", _headers, _body ->
        {:ok, 200,
         %{
           "data" => [
             %{
               "id" => "998877",
               "login" => "streamer",
               "display_name" => "StreamerLive"
             }
           ]
         }}
    end

    Application.put_env(:chat_overlay, :oauth_http_client, mock_client)

    state = OAuth.generate_state("streamer", "twitch", "test_verifier_string")

    callback_path =
      "/oauth/callback/twitch?code=auth_code_xyz&state=#{URI.encode_www_form(state)}"

    {302, headers, _} = request(port, "GET", callback_path)

    # 1. Location redirect
    {_, location} = List.keyfind(headers, "location", 0)
    assert location =~ "/?handle=streamer&linked=twitch"

    # 2. Set-Cookie emission
    set_cookies =
      headers
      |> Enum.filter(fn {k, _} -> k == "set-cookie" end)
      |> Enum.map(&elem(&1, 1))

    session_cookie =
      Enum.find(set_cookies, fn c -> String.starts_with?(c, "#{Session.cookie_name()}=") end)

    assert session_cookie != nil
    assert session_cookie =~ "HttpOnly"
    assert session_cookie =~ "SameSite=Lax"
    assert session_cookie =~ "path=/"

    # Extract token and verify its integrity and payload
    [cookie_val | _] = String.split(session_cookie, ";")
    token = String.replace_prefix(cookie_val, "#{Session.cookie_name()}=", "")

    assert {:ok, session} = Session.verify_token(token)
    assert session["handle"] == "streamer"
    assert session["provider"] == "twitch"
    assert session["user_id"] == "998877"
  end

  test "GET /api/profiles without session on loopback only exposes demo profiles", %{port: port} do
    {200, _, body} = request(port, "GET", "/api/profiles", [])
    assert {:ok, data} = JSON.decode(body)
    handles = Enum.map(data["profiles"], & &1["handle"])
    assert "streamer" in handles
    assert "streamer2" in handles
    refute "streamer-prod" in handles
  end

  test "GET /api/oauth/authorize/:provider enforces profile authorization", %{port: port} do
    cookie_streamer = session_cookie_header("streamer")
    cookie_prod = session_cookie_header("streamer-prod")

    # 1. Unauthenticated request to authorize non-demo profile -> 401
    {401, _, unauth_body} =
      request(port, "GET", "/api/oauth/authorize/twitch?handle=streamer-prod")

    assert {:ok, unauth_data} = JSON.decode(unauth_body)
    assert unauth_data["ok"] == false

    # 2. Authenticated as different user -> 403 Forbidden
    {403, _, forbidden_body} =
      request(port, "GET", "/api/oauth/authorize/twitch?handle=streamer-prod", [cookie_streamer])

    assert {:ok, forbidden_data} = JSON.decode(forbidden_body)
    assert forbidden_data["ok"] == false

    # 3. Authenticated as profile owner -> 200 OK with url
    {200, _, ok_body} =
      request(port, "GET", "/api/oauth/authorize/twitch?handle=streamer-prod", [cookie_prod])

    assert {:ok, ok_data} = JSON.decode(ok_body)
    assert ok_data["ok"] == true
    assert is_binary(ok_data["url"])
  end

  test "POST /api/auth/logout revokes the token preventing reuse across sessions", %{port: port} do
    origin = {"origin", "http://localhost:#{port}"}
    {:ok, token} = Session.create_token(%{"handle" => "streamer"})
    cookie_header = {"cookie", "#{Session.cookie_name()}=#{token}"}

    # Verify active session
    {200, _, me_body1} = request(port, "GET", "/api/auth/me", [cookie_header])
    assert {:ok, me_data1} = JSON.decode(me_body1)
    assert me_data1["authenticated"] == true

    # Logout
    {200, _, logout_body} = request(port, "POST", "/api/auth/logout", [origin, cookie_header])
    assert {:ok, logout_data} = JSON.decode(logout_body)
    assert logout_data["ok"] == true

    # Re-using the same token header is now rejected as unauthenticated (revoked)
    {200, _, me_body2} = request(port, "GET", "/api/auth/me", [cookie_header])
    assert {:ok, me_data2} = JSON.decode(me_body2)
    assert me_data2["authenticated"] == false
  end

  test "OAuth callback rejects identity mismatch for established profile owner", %{port: port} do
    # Configure mock OAuth client returning mismatched user_id (not 12345)
    mock_client = fn
      :post, "https://id.twitch.tv/oauth2/token", _headers, _body ->
        {:ok, 200,
         %{
           "access_token" => "mock_twitch_token_attacker",
           "refresh_token" => "mock_twitch_refresh_attacker",
           "expires_in" => 3600
         }}

      :get, "https://api.twitch.tv/helix/users", _headers, _body ->
        {:ok, 200,
         %{
           "data" => [
             %{
               "id" => "999999",
               "login" => "attacker",
               "display_name" => "Attacker"
             }
           ]
         }}
    end

    Application.put_env(:chat_overlay, :oauth_http_client, mock_client)

    on_exit(fn ->
      Application.delete_env(:chat_overlay, :oauth_http_client)
    end)

    # State requested for streamer-prod (whose configured user_id is 12345)
    state = OAuth.generate_state("streamer-prod", "twitch", "test_verifier_attacker")

    callback_path =
      "/oauth/callback/twitch?code=auth_code_attacker&state=#{URI.encode_www_form(state)}"

    {302, headers, _} = request(port, "GET", callback_path)

    # Must redirect with error=identity_mismatch and NOT issue session cookie
    {_, location} = List.keyfind(headers, "location", 0)
    assert location =~ "error=identity_mismatch"

    set_cookies =
      headers
      |> Enum.filter(fn {k, _} -> k == "set-cookie" end)
      |> Enum.map(&elem(&1, 1))

    session_cookie =
      Enum.find(set_cookies, fn c -> String.starts_with?(c, "#{Session.cookie_name()}=") end)

    assert session_cookie == nil
  end
end
