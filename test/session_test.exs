defmodule ChatOverlay.SessionTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias ChatOverlay.{Crypto, JSON, Session}

  @test_key "secret_test_encryption_key_32_b!"

  setup do
    original_profiles = Application.get_env(:chat_overlay, :profiles, [])

    on_exit(fn ->
      Application.put_env(:chat_overlay, :profiles, original_profiles)
    end)

    demo_profile = %{
      "handle" => "streamer-demo",
      "sources" => [
        %{"platform" => "twitch", "channel" => "streamer-demo", "mode" => "demo"}
      ]
    }

    prod_profile = %{
      "handle" => "streamer-prod",
      "sources" => [
        %{"platform" => "twitch", "channel" => "streamer-prod"}
      ]
    }

    Application.put_env(:chat_overlay, :profiles, [demo_profile, prod_profile])
    :ok
  end

  describe "token generation and verification" do
    test "creates and verifies a valid session token" do
      payload = %{
        "handle" => "streamer",
        "provider" => "twitch",
        "user_id" => "12345",
        "username" => "StreamerName"
      }

      assert {:ok, token} = Session.create_token(payload, key: @test_key)
      assert String.starts_with?(token, "v1:")

      assert {:ok, session} = Session.verify_token(token, key: @test_key)
      assert session["handle"] == "streamer"
      assert session["provider"] == "twitch"
      assert session["user_id"] == "12345"
      assert session["username"] == "StreamerName"
      assert is_integer(session["created_at"])
      assert is_integer(session["expires_at"])
      assert session["expires_at"] > session["created_at"]
    end

    test "rejects missing or empty handle" do
      assert {:error, :invalid_handle} = Session.create_token(%{"handle" => ""})
      assert {:error, :invalid_handle} = Session.create_token(%{"user_id" => "123"})
    end

    test "rejects expired session token" do
      now = 1_000_000
      payload = %{"handle" => "streamer"}

      assert {:ok, token} =
               Session.create_token(payload, key: @test_key, now: now, max_age: 100)

      # Verifying within validity window
      assert {:ok, _} = Session.verify_token(token, key: @test_key, now: now + 50)

      # Verifying after expiration
      assert {:error, :session_expired} =
               Session.verify_token(token, key: @test_key, now: now + 101)
    end

    test "rejects tampered token" do
      payload = %{"handle" => "streamer"}
      assert {:ok, "v1:" <> encoded} = Session.create_token(payload, key: @test_key)

      # Tamper with the base64 content
      tampered = "v1:" <> "A" <> binary_part(encoded, 1, byte_size(encoded) - 1)
      assert {:error, :invalid_or_tampered_token} = Session.verify_token(tampered, key: @test_key)

      # Non-v1 prefix
      assert {:error, :invalid_token} = Session.verify_token("invalid_token")
    end

    test "rejects token encrypted with different key" do
      other_key = "different_secret_key_32_bytes!!"
      payload = %{"handle" => "streamer"}
      assert {:ok, token} = Session.create_token(payload, key: @test_key)

      assert {:error, :invalid_or_tampered_token} = Session.verify_token(token, key: other_key)
    end

    test "rejects ciphertext encrypted with different AAD (domain separation)" do
      # If an attacker tries to pass an OAuth state ciphertext as a session token
      json =
        JSON.encode(%{"handle" => "streamer", "expires_at" => System.system_time(:second) + 1000})

      {:ok, oauth_state_cipher} = Crypto.encrypt_aead(json, @test_key, "oauth_state")

      # Should be rejected because session requires AAD "chat_overlay_session"
      assert {:error, :invalid_or_tampered_token} =
               Session.verify_token(oauth_state_cipher, key: @test_key)
    end
  end

  describe "cookie lifecycle in Plug.Conn" do
    test "put_session sets HttpOnly, SameSite=Lax and conditional Secure flags" do
      # HTTP scheme without HTTPS header -> Secure is false
      conn_http = conn(:get, "/")
      conn_http = Session.put_session(conn_http, %{"handle" => "streamer"}, key: @test_key)
      resp_http = Plug.Conn.send_resp(conn_http, 200, "ok")
      [cookie_http] = Plug.Conn.get_resp_header(resp_http, "set-cookie")

      assert cookie_http =~ "chat_overlay_session=v1:"
      assert cookie_http =~ "HttpOnly"
      assert cookie_http =~ "SameSite=Lax"
      assert cookie_http =~ "max-age=604800"
      refute cookie_http =~ "secure;"

      # HTTPS scheme -> Secure is true
      conn_https = %{conn(:get, "/") | scheme: :https}
      conn_https = Session.put_session(conn_https, %{"handle" => "streamer"}, key: @test_key)
      resp_https = Plug.Conn.send_resp(conn_https, 200, "ok")
      [cookie_https] = Plug.Conn.get_resp_header(resp_https, "set-cookie")

      assert cookie_https =~ "chat_overlay_session=v1:"
      assert cookie_https =~ "HttpOnly"
      assert cookie_https =~ "SameSite=Lax"
      assert cookie_https =~ "secure"

      # HTTP with x-forwarded-proto: https -> Secure is true
      conn_forwarded =
        conn(:get, "/")
        |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
        |> Session.put_session(%{"handle" => "streamer"}, key: @test_key)

      resp_forwarded = Plug.Conn.send_resp(conn_forwarded, 200, "ok")
      [cookie_fwd] = Plug.Conn.get_resp_header(resp_forwarded, "set-cookie")
      assert cookie_fwd =~ "secure"
    end

    test "delete_session invalidates cookie with max-age=0" do
      conn = conn(:get, "/") |> Session.delete_session()
      resp = Plug.Conn.send_resp(conn, 200, "ok")
      [cookie] = Plug.Conn.get_resp_header(resp, "set-cookie")

      assert cookie =~ "chat_overlay_session=;"
      assert cookie =~ "max-age=0"
      assert cookie =~ "HttpOnly"
    end

    test "fetch_session retrieves and verifies session cookie" do
      {:ok, token} = Session.create_token(%{"handle" => "streamer"}, key: @test_key)

      conn_with_cookie =
        conn(:get, "/")
        |> put_req_header("cookie", "chat_overlay_session=#{token}")

      assert {:ok, session} = Session.fetch_session(conn_with_cookie, key: @test_key)
      assert session["handle"] == "streamer"

      # Missing cookie
      conn_empty = conn(:get, "/")
      assert {:error, :no_session} = Session.fetch_session(conn_empty, key: @test_key)
    end
  end

  describe "authorization and scope" do
    test "authorize/3 allows matching session" do
      {:ok, token} = Session.create_token(%{"handle" => "streamer-prod"}, key: @test_key)

      conn =
        conn(:get, "/")
        |> put_req_header("cookie", "chat_overlay_session=#{token}")

      assert :ok = Session.authorize(conn, "streamer-prod", key: @test_key)
    end

    test "authorize/3 rejects cross-profile access with 403 forbidden" do
      {:ok, token} = Session.create_token(%{"handle" => "streamer-prod"}, key: @test_key)

      conn =
        conn(:get, "/")
        |> put_req_header("cookie", "chat_overlay_session=#{token}")

      # streamer-prod trying to access another profile
      assert {:error, :forbidden} = Session.authorize(conn, "streamer-demo", key: @test_key)
      assert {:error, :forbidden} = Session.authorize(conn, "other-streamer", key: @test_key)
    end

    test "authorize/3 allows unauthenticated loopback access for demo and nonexistent profiles" do
      # Loopback (127.0.0.1) on demo profile
      conn_loopback = conn(:get, "/")
      assert :ok = Session.authorize(conn_loopback, "streamer-demo")
      assert :ok = Session.authorize(conn_loopback, "demo")

      # Loopback on nonexistent profile allows 404 handling downstream
      assert :ok = Session.authorize(conn_loopback, "nonexistent-profile")
    end

    test "authorize/3 rejects unauthenticated access for production non-demo profile" do
      # Even on loopback, production non-demo profiles require session
      conn_loopback = conn(:get, "/")
      assert {:error, :unauthorized} = Session.authorize(conn_loopback, "streamer-prod")
    end

    test "authorize/3 rejects unauthenticated access from non-loopback IPs" do
      conn_remote = %{conn(:get, "/") | remote_ip: {198, 51, 100, 1}}
      assert {:error, :unauthorized} = Session.authorize(conn_remote, "streamer-demo")
      assert {:error, :unauthorized} = Session.authorize(conn_remote, "streamer-prod")
      assert {:error, :unauthorized} = Session.authorize(conn_remote, "nonexistent")
    end

    test "authorize_profile_creation/3 enforces session or demo loopback" do
      demo_params = %{
        "handle" => "new-demo",
        "sources" => [%{"platform" => "twitch", "channel" => "demo", "mode" => "demo"}]
      }

      prod_params = %{
        "handle" => "new-prod",
        "sources" => [%{"platform" => "twitch", "channel" => "real_channel"}]
      }

      conn_loopback = conn(:post, "/api/profiles")
      conn_remote = %{conn(:post, "/api/profiles") | remote_ip: {198, 51, 100, 1}}

      # Loopback with demo payload -> allowed
      assert :ok = Session.authorize_profile_creation(conn_loopback, demo_params)

      # Loopback with production payload without session -> 401
      assert {:error, :unauthorized} =
               Session.authorize_profile_creation(conn_loopback, prod_params)

      # Remote without session -> 401
      assert {:error, :unauthorized} =
               Session.authorize_profile_creation(conn_remote, demo_params)

      # With matching session -> allowed
      {:ok, token} = Session.create_token(%{"handle" => "new-prod"}, key: @test_key)

      conn_with_auth =
        conn_remote
        |> put_req_header("cookie", "chat_overlay_session=#{token}")

      assert :ok =
               Session.authorize_profile_creation(conn_with_auth, prod_params, key: @test_key)

      # With mismatched session -> forbidden (403)
      assert {:error, :forbidden} =
               Session.authorize_profile_creation(conn_with_auth, demo_params, key: @test_key)
    end

    test "scope_profiles/3 isolates profiles by session handle" do
      profiles = [
        %{
          "handle" => "streamer-prod",
          "sources" => [
            %{"platform" => "twitch", "channel" => "streamer-prod", "mode" => "prod"}
          ]
        },
        %{
          "handle" => "streamer-demo",
          "sources" => [
            %{"platform" => "twitch", "channel" => "streamer-demo", "mode" => "demo"}
          ]
        }
      ]

      # Authenticated as streamer-prod -> only sees streamer-prod
      {:ok, token} = Session.create_token(%{"handle" => "streamer-prod"}, key: @test_key)

      conn_auth =
        conn(:get, "/api/profiles")
        |> put_req_header("cookie", "chat_overlay_session=#{token}")

      assert {:ok, scoped} = Session.scope_profiles(conn_auth, profiles, key: @test_key)
      assert length(scoped) == 1
      assert hd(scoped)["handle"] == "streamer-prod"

      # Unauthenticated loopback -> sees only demo profiles
      conn_loopback = conn(:get, "/api/profiles")
      assert {:ok, demo_only} = Session.scope_profiles(conn_loopback, profiles)
      assert length(demo_only) == 1
      assert hd(demo_only)["handle"] == "streamer-demo"

      # Unauthenticated remote -> 401
      conn_remote = %{conn(:get, "/api/profiles") | remote_ip: {198, 51, 100, 1}}
      assert {:error, :unauthorized} = Session.scope_profiles(conn_remote, profiles)
    end

    test "revoke_token/1 invalidates active session tokens" do
      {:ok, token} = Session.create_token(%{"handle" => "streamer"}, key: @test_key)
      assert {:ok, _} = Session.verify_token(token, key: @test_key)

      assert :ok = Session.revoke_token(token)
      assert Session.revoked?(token)
      assert {:error, :revoked} = Session.verify_token(token, key: @test_key)
    end

    test "delete_session/2 automatically revokes the session token" do
      {:ok, token} = Session.create_token(%{"handle" => "streamer"}, key: @test_key)

      conn =
        conn(:post, "/api/auth/logout")
        |> put_req_header("cookie", "chat_overlay_session=#{token}")

      _conn = Session.delete_session(conn)
      assert Session.revoked?(token)
      assert {:error, :revoked} = Session.verify_token(token, key: @test_key)
    end

    test "authorize/3 invalidates session when provider account is unlinked or mismatched" do
      prod_with_link = %{
        "handle" => "streamer-linked",
        "sources" => [%{"platform" => "twitch", "channel" => "streamer-linked"}],
        "linked_accounts" => %{
          "twitch" => %{"user_id" => "55555", "username" => "linked_user", "account_version" => 1}
        }
      }

      Application.put_env(:chat_overlay, :profiles, [prod_with_link])

      {:ok, token} =
        Session.create_token(
          %{
            "handle" => "streamer-linked",
            "provider" => "twitch",
            "user_id" => "55555",
            "account_version" => 1
          },
          key: @test_key
        )

      conn =
        conn(:get, "/")
        |> put_req_header("cookie", "chat_overlay_session=#{token}")

      # 1. Matching linked account -> authorized
      assert :ok = Session.authorize(conn, "streamer-linked", key: @test_key)

      # 2. When account is unlinked (linked_accounts is empty or provider missing) -> 401 unauthorized
      prod_unlinked = %{prod_with_link | "linked_accounts" => %{}}
      Application.put_env(:chat_overlay, :profiles, [prod_unlinked])

      assert {:error, :unauthorized} =
               Session.authorize(conn, "streamer-linked", key: @test_key)

      # 3. When user_id changed -> 401 unauthorized
      prod_changed_user =
        put_in(prod_with_link, ["linked_accounts", "twitch", "user_id"], "99999")

      Application.put_env(:chat_overlay, :profiles, [prod_changed_user])

      assert {:error, :unauthorized} =
               Session.authorize(conn, "streamer-linked", key: @test_key)

      # 4. When account_version changed -> 401 unauthorized
      prod_changed_version =
        put_in(prod_with_link, ["linked_accounts", "twitch", "account_version"], 2)

      Application.put_env(:chat_overlay, :profiles, [prod_changed_version])

      assert {:error, :unauthorized} =
               Session.authorize(conn, "streamer-linked", key: @test_key)
    end
  end
end
