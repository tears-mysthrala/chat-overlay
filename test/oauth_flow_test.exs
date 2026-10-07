defmodule ChatOverlay.OAuthFlowTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{OAuth, OAuthFlow}

  setup do
    origin = Application.get_env(:chat_overlay, :oauth_origin)
    Application.put_env(:chat_overlay, :oauth_origin, "https://localhost")
    on_exit(fn -> Application.put_env(:chat_overlay, :oauth_origin, origin) end)
  end

  defp flow(handle \\ "flow-test", ip \\ {127, 0, 0, 1}) do
    state = OAuth.generate_state(handle, "twitch", "verifier")

    {:ok, conn} =
      OAuthFlow.bind(
        %{Plug.Test.conn(:get, "https://localhost/") | remote_ip: ip},
        state,
        "twitch"
      )

    cookie = conn.resp_cookies[OAuthFlow.cookie_name(state, true)]

    browser =
      Plug.Test.conn(:get, "https://localhost/oauth/callback/twitch")
      |> Plug.Conn.put_req_header(
        "cookie",
        "#{OAuthFlow.cookie_name(state, true)}=#{cookie.value}"
      )

    {state, browser, cookie}
  end

  test "matching browser consumes once; copied state alone or another cookie cannot consume" do
    {state, browser, cookie} = flow()
    assert cookie.http_only and cookie.secure
    assert cookie.same_site == "Lax"
    assert cookie.path == "/"
    assert {:error, :invalid_flow} = OAuthFlow.consume(Plug.Test.conn(:get, "/"), state, "twitch")
    {other_state, other_browser, _} = flow("other-flow")
    assert {:error, :invalid_flow} = OAuthFlow.consume(other_browser, state, "twitch")
    assert {:error, :duplicate_flow} = OAuthFlow.bind(other_browser, state, "twitch")
    assert {:error, :invalid_flow} = OAuthFlow.consume(browser, state, "youtube")
    assert {:ok, conn} = OAuthFlow.consume(browser, state, "twitch")
    assert conn.resp_cookies[OAuthFlow.cookie_name(state, true)].max_age == 0
    assert {:error, :invalid_flow} = OAuthFlow.consume(browser, state, "twitch")
    assert {:ok, _} = OAuthFlow.consume(other_browser, other_state, "twitch")
  end

  test "concurrent callbacks admit one caller" do
    {state, browser, _} = flow()

    results =
      1..20
      |> Task.async_stream(fn _ -> OAuthFlow.consume(browser, state, "twitch") end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_flow})) == 19
  end

  test "per-requester bound preserves space for another creator and login client" do
    flows = Enum.map(1..4, fn _ -> flow("full-flow") end)
    state = OAuth.generate_state("full-flow", "twitch", "verifier")

    assert {:error, :flow_capacity} =
             OAuthFlow.bind(Plug.Test.conn(:get, "https://localhost/"), state, "twitch")

    {login, client, _} = flow("full-flow", {203, 0, 113, 2})
    assert {:ok, _} = OAuthFlow.consume(client, login, "twitch")
    {other, browser, _} = flow("spare-flow")
    assert {:ok, _} = OAuthFlow.consume(browser, other, "twitch")
    Enum.each(flows, fn {s, b, _} -> assert {:ok, _} = OAuthFlow.consume(b, s, "twitch") end)
  end

  test "expired transaction is rejected and reclaimed" do
    {state, browser, _} = flow("expired-flow")
    # Move this transaction's deadline into the past without sleeping for ten minutes.
    :sys.replace_state(OAuthFlow, fn entries ->
      Map.update!(entries, :crypto.hash(:sha256, state), fn {b, h, p, _, grant} ->
        {b, h, p, System.monotonic_time(:second) - 1, grant}
      end)
    end)

    assert {:error, :invalid_flow} = OAuthFlow.consume(browser, state, "twitch")
    refute Map.has_key?(:sys.get_state(OAuthFlow), :crypto.hash(:sha256, state))
  end

  test "restarting the owner cancels outstanding transactions" do
    {state, browser, _} = flow("restart-flow")
    :ok = Supervisor.terminate_child(ChatOverlay.Application.Supervisor, OAuthFlow)
    {:ok, _} = Supervisor.restart_child(ChatOverlay.Application.Supervisor, OAuthFlow)
    assert {:error, :invalid_flow} = OAuthFlow.consume(browser, state, "twitch")
    {fresh, fresh_browser, _} = flow("restart-flow")
    assert {:ok, _} = OAuthFlow.consume(fresh_browser, fresh, "twitch")
  end

  test "non-loopback HTTP cannot issue an insecure transaction cookie" do
    state = OAuth.generate_state("transport-flow", "twitch", "verifier")
    conn = %{Plug.Test.conn(:get, "http://example.test/") | remote_ip: {203, 0, 113, 1}}
    assert {:error, :insecure_transport} = OAuthFlow.bind(conn, state, "twitch")
    ambiguous = conn |> Plug.Conn.put_req_header("x-forwarded-proto", "https,http")
    assert {:error, :insecure_transport} = OAuthFlow.bind(ambiguous, state, "twitch")
    forwarded = conn |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
    assert {:error, :insecure_transport} = OAuthFlow.bind(forwarded, state, "twitch")
    origin = Application.get_env(:chat_overlay, :oauth_origin)
    Application.put_env(:chat_overlay, :oauth_origin, "https://example.test")
    on_exit(fn -> Application.put_env(:chat_overlay, :oauth_origin, origin) end)
    original = Application.get_env(:chat_overlay, :trusted_proxy_ips, [])
    Application.put_env(:chat_overlay, :trusted_proxy_ips, [{203, 0, 113, 1}])
    on_exit(fn -> Application.put_env(:chat_overlay, :trusted_proxy_ips, original) end)
    assert {:ok, secured} = OAuthFlow.bind(forwarded, state, "twitch")
    assert secured.resp_cookies[OAuthFlow.cookie_name(state, true)].secure
  end

  test "two pending transactions in one browser remain independently usable" do
    {first, _, cookie1} = flow("parallel-flow")
    {second, _, cookie2} = flow("parallel-flow")
    refute cookie1.value == cookie2.value

    browser =
      Plug.Test.conn(:get, "https://localhost/oauth/callback/twitch")
      |> Plug.Conn.put_req_header(
        "cookie",
        "#{OAuthFlow.cookie_name(first, true)}=#{cookie1.value}; #{OAuthFlow.cookie_name(second, true)}=#{cookie2.value}"
      )

    assert {:ok, _} = OAuthFlow.consume(browser, second, "twitch")
    assert {:ok, _} = OAuthFlow.consume(browser, first, "twitch")
    assert {:error, :invalid_flow} = OAuthFlow.consume(browser, second, "twitch")
  end

  test "anonymous reservations do not consume the owner's lane" do
    flows = Enum.map(1..4, fn _ -> flow("reserved-owner") end)

    state =
      OAuth.generate_state("reserved-owner", "twitch", "verifier", %{
        "auth_proof" => "capability_token"
      })

    assert {:ok, owner} =
             OAuthFlow.bind(Plug.Test.conn(:get, "https://localhost/"), state, "twitch")

    browser =
      Plug.Test.conn(:get, "https://localhost/")
      |> Plug.Conn.put_req_header(
        "cookie",
        "#{OAuthFlow.cookie_name(state, true)}=#{owner.resp_cookies[OAuthFlow.cookie_name(state, true)].value}"
      )

    assert {:ok, _} = OAuthFlow.consume(browser, state, "twitch")
    Enum.each(flows, fn {s, b, _} -> assert {:ok, _} = OAuthFlow.consume(b, s, "twitch") end)
  end

  test "trusted loopback proxy cannot use the local HTTP exemption" do
    original = Application.get_env(:chat_overlay, :trusted_proxy_ips, [])
    Application.put_env(:chat_overlay, :trusted_proxy_ips, [{127, 0, 0, 1}])
    on_exit(fn -> Application.put_env(:chat_overlay, :trusted_proxy_ips, original) end)
    state = OAuth.generate_state("proxy-local", "twitch", "verifier")
    conn = %{Plug.Test.conn(:get, "http://localhost/") | remote_ip: {127, 0, 0, 1}}
    assert {:error, :insecure_transport} = OAuthFlow.bind(conn, state, "twitch")
  end

  test "authorization snapshot rejects a changed capability" do
    profile = %{"handle" => "snapshot", "capability_token_hash" => "original"}

    state =
      OAuth.generate_state("snapshot", "twitch", "verifier", %{"auth_proof" => "capability_token"})

    {:ok, issued} =
      OAuthFlow.bind(Plug.Test.conn(:get, "https://localhost/"), state, "twitch", profile)

    browser =
      Plug.Test.conn(:get, "https://localhost/")
      |> Plug.Conn.put_req_header(
        "cookie",
        "#{OAuthFlow.cookie_name(state, true)}=#{issued.resp_cookies[OAuthFlow.cookie_name(state, true)].value}"
      )

    {:ok, consumed} = OAuthFlow.consume(browser, state, "twitch")
    assert OAuthFlow.authorized?(consumed, "snapshot", profile)

    assert OAuthFlow.authorized?(
             consumed,
             "snapshot",
             Map.put(profile, "media", %{"image" => "changed"})
           )

    refute OAuthFlow.authorized?(
             consumed,
             "snapshot",
             Map.put(profile, "capability_token_hash", "regenerated")
           )
  end

  test "session grant cannot use demo fallback after revocation" do
    profile = %{"handle" => "demo", "sources" => []}
    original = Application.get_env(:chat_overlay, :profiles, [])
    Application.put_env(:chat_overlay, :profiles, [profile])
    on_exit(fn -> Application.put_env(:chat_overlay, :profiles, original) end)
    {:ok, token} = ChatOverlay.Session.create_token(%{"handle" => "demo"})
    state = OAuth.generate_state("demo", "twitch", "verifier", %{"auth_proof" => "session"})

    conn =
      Plug.Test.conn(:get, "https://localhost/")
      |> Plug.Conn.put_req_header("cookie", "#{ChatOverlay.Session.cookie_name()}=#{token}")

    {:ok, issued} = OAuthFlow.bind(conn, state, "twitch", profile)

    browser =
      Plug.Test.conn(:get, "https://localhost/")
      |> Plug.Conn.put_req_header(
        "cookie",
        "#{ChatOverlay.Session.cookie_name()}=#{token}; #{OAuthFlow.cookie_name(state, true)}=#{issued.resp_cookies[OAuthFlow.cookie_name(state, true)].value}"
      )

    {:ok, consumed} = OAuthFlow.consume(browser, state, "twitch")
    assert OAuthFlow.authorized?(consumed, "demo", profile)
    :ok = ChatOverlay.Session.revoke_token(token)
    refute OAuthFlow.authorized?(consumed, "demo", profile)

    assert {:error, :authorization_changed} =
             ChatOverlay.Profiles.link_account("demo", "twitch", %{}, %{}, fn current ->
               OAuthFlow.authorized?(consumed, "demo", current)
             end)
  end
end
