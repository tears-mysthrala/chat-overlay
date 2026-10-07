defmodule ChatOverlay.WebOAuthTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{JSON, Profiles}

  setup_all do
    Application.put_env(:chat_overlay, :port, 0)
    start_supervised!(ChatOverlay.HTTP)
    %{port: ChatOverlay.HTTP.port()}
  end

  setup do
    original_profiles = Application.get_env(:chat_overlay, :profiles, [])

    on_exit(fn ->
      Application.put_env(:chat_overlay, :profiles, original_profiles)
    end)

    profile = %{
      "handle" => "streamer",
      "sources" => [
        %{"platform" => "twitch", "channel" => "streamer", "mode" => "demo"}
      ]
    }

    Application.put_env(:chat_overlay, :profiles, [profile])
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

  test "GET /api/oauth/authorize/:provider returns authorization URL", %{port: port} do
    {200, headers, body} = request(port, "GET", "/api/oauth/authorize/twitch?handle=streamer")
    assert Enum.any?(headers, fn {k, v} -> k == "content-type" and v =~ "application/json" end)
    {:ok, data} = JSON.decode(body)
    assert data["ok"] == true
    assert data["url"] =~ "https://id.twitch.tv/oauth2/authorize"
    assert data["url"] =~ "client_id="
    assert data["url"] =~ "state="
    assert data["url"] =~ "code_challenge="
    state = URI.decode_query(URI.parse(data["url"]).query)["state"]
    assert {:ok, %{"auth_proof" => "demo"}} = ChatOverlay.OAuth.verify_state(state)
  end

  test "GET /api/oauth/authorize/:provider rejects unconfigured provider credentials", %{
    port: port
  } do
    original_id = Application.get_env(:chat_overlay, :twitch_client_id)
    Application.delete_env(:chat_overlay, :twitch_client_id)
    System.delete_env("TWITCH_CLIENT_ID")

    try do
      {400, _, body} = request(port, "GET", "/api/oauth/authorize/twitch?handle=streamer")
      {:ok, data} = JSON.decode(body)
      assert data["ok"] == false
      assert data["error"] =~ "no tiene client_id configurado"
    after
      if original_id, do: Application.put_env(:chat_overlay, :twitch_client_id, original_id)
    end
  end

  test "GET /api/oauth/authorize/:provider rejects unknown handle", %{port: port} do
    {404, _, body} = request(port, "GET", "/api/oauth/authorize/twitch?handle=nonexistent")
    {:ok, data} = JSON.decode(body)
    assert data["ok"] == false
    assert data["error"] =~ "Perfil no encontrado"
  end

  test "GET /api/oauth/authorize/:provider rejects unsupported provider", %{port: port} do
    {400, _, body} = request(port, "GET", "/api/oauth/authorize/unsupported?handle=streamer")
    {:ok, data} = JSON.decode(body)
    assert data["ok"] == false
    assert data["error"] =~ "Proveedor no soportado"
  end

  test "GET /oauth/callback/:provider redirects on upstream error", %{port: port} do
    state = ChatOverlay.OAuth.generate_state("streamer", "twitch", "verifier")

    {:ok, conn} =
      ChatOverlay.OAuthFlow.bind(Plug.Test.conn(:get, "http://localhost/"), state, "twitch")

    cookie = conn.resp_cookies[ChatOverlay.OAuthFlow.cookie_name(state)].value

    {302, headers, _} =
      request(
        port,
        "GET",
        "/oauth/callback/twitch?error=access_denied&state=#{URI.encode_www_form(state)}",
        [{"cookie", "#{ChatOverlay.OAuthFlow.cookie_name(state)}=#{cookie}"}]
      )

    {_, location} = List.keyfind(headers, "location", 0)
    assert location =~ "/?handle=streamer&error=access_denied"
  end

  test "POST /api/profiles/:handle/unlink/:provider unlinks account with origin check", %{
    port: port
  } do
    # First link account
    {:ok, _} =
      Profiles.link_account(
        "streamer",
        "twitch",
        %{username: "StreamerTwitch", user_id: "123"},
        %{"access_token" => "tok"}
      )

    # 1. Deny invalid origin (CSRF)
    {403, _, _} =
      request(
        port,
        "POST",
        "/api/profiles/streamer/unlink/twitch",
        [{"origin", "https://malicious-site.com"}]
      )

    # 2. Allow valid origin
    valid_origin = "http://localhost:#{port}"

    {200, _, body} =
      request(
        port,
        "POST",
        "/api/profiles/streamer/unlink/twitch",
        [{"origin", valid_origin}]
      )

    {:ok, data} = JSON.decode(body)
    assert data["ok"] == true
    assert data["unlinked"] == "twitch"

    profile = Profiles.get("streamer")
    refute Map.has_key?(profile["linked_accounts"], "twitch")
  end

  test "callback rejects copied state before contacting upstream and denial consumes the flow", %{
    port: port
  } do
    original = Application.get_env(:chat_overlay, :oauth_http_client)
    parent = self()

    Application.put_env(:chat_overlay, :oauth_http_client, fn _, _, _, _ ->
      send(parent, :upstream_called)
      {:error, :unexpected_upstream}
    end)

    on_exit(fn ->
      if original,
        do: Application.put_env(:chat_overlay, :oauth_http_client, original),
        else: Application.delete_env(:chat_overlay, :oauth_http_client)
    end)

    {200, headers, body} = request(port, "GET", "/api/oauth/authorize/twitch?handle=streamer")
    {:ok, data} = JSON.decode(body)

    state =
      data["url"]
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    {_, cookie} = List.keyfind(headers, "set-cookie", 0)
    browser = [{"cookie", cookie |> String.split(";") |> hd()}]
    path = "/oauth/callback/twitch?state=#{URI.encode_www_form(state)}"
    {302, rejected, _} = request(port, "GET", path <> "&code=synthetic")
    assert elem(List.keyfind(rejected, "location", 0), 1) == "/?error=invalid_oauth_flow"
    refute_received :upstream_called

    {302, denied, _} = request(port, "GET", path <> "&error=access_denied", browser)
    assert elem(List.keyfind(denied, "location", 0), 1) =~ "error=access_denied"
    {302, replay, _} = request(port, "GET", path <> "&code=synthetic", browser)
    assert elem(List.keyfind(replay, "location", 0), 1) == "/?error=invalid_oauth_flow"
    refute_received :upstream_called
  end

  test "HTTPS on localhost builds an HTTPS callback URI" do
    conn =
      Plug.Test.conn(:get, "https://localhost/api/oauth/authorize/twitch?handle=streamer")
      |> ChatOverlay.Web.call([])

    assert conn.status == 200
    {:ok, data} = JSON.decode(conn.resp_body)
    params = data["url"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["redirect_uri"] == "https://localhost/oauth/callback/twitch"
  end
end
