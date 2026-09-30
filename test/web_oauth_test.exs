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

    {302, headers, _} =
      request(
        port,
        "GET",
        "/oauth/callback/twitch?error=access_denied&state=#{URI.encode_www_form(state)}"
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
end
