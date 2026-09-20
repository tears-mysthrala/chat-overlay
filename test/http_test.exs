defmodule ChatOverlay.HTTPTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{JSON, Store, Config, Source}

  setup_all do
    Application.put_env(:chat_overlay, :port, 0)
    start_supervised!(ChatOverlay.HTTP)
    %{port: ChatOverlay.HTTP.port()}
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

  test "real HTTP enforces methods, routes, configured profiles and security headers", %{
    port: port
  } do
    assert {200, headers, home} = request(port, "GET", "/")
    assert home =~ "La conversación"
    assert {"x-content-type-options", "nosniff"} in headers
    assert {"cache-control", "no-store"} in headers

    assert Enum.any?(headers, fn {k, v} ->
             k == "content-security-policy" and v =~ "default-src 'none'"
           end)

    assert {200, _, "ready"} = request(port, "GET", "/health/ready")
    assert {200, _, html} = request(port, "GET", "/reader/test")
    assert html =~ ~s(data-demo="true")
    assert {404, _, _} = request(port, "GET", "/reader/private")
    assert {404, _, _} = request(port, "GET", "/events/private")
    assert {404, _, _} = request(port, "GET", "/assets/config.json")
    assert {405, _, _} = request(port, "POST", "/events/test")
    assert {405, _, _} = request(port, "POST", "/reader/test")

    assert {403, _, _} =
             request(port, "POST", "/hooks/kick", [{"content-type", "application/json"}], "{}")

    assert {413, _, _} = request(port, "POST", "/hooks/kick", [], String.duplicate("x", 65537))
  end

  test "SSE sends reset/snapshot, bounded batches and a resumable cursor", %{port: port} do
    conn = connection(port)
    ref = ChatOverlay.TestClient.get(conn, "/events/test")
    assert {:response, :nofin, 200, headers} = ChatOverlay.TestClient.await(conn, ref)
    assert {"content-type", "text/event-stream; charset=utf-8"} in headers
    data = read_batch(conn, ref, "")
    assert data =~ "event: batch"
    assert data =~ ~s("event":"snapshot")
    assert data =~ ~s("event":"reset")
    assert data =~ "retry: 2000"
    first_conn = conn
    wait_until(fn -> Source.active?(hd(Config.profile("test")["sources"])) end)
    Process.sleep(20)
    cursor = Store.read(Store.name("test")).cursor

    event =
      ChatOverlay.Event.new("twitch", "test-channel", "message", "http-test", %{
        "message_id" => "http-message",
        "author_id" => "alice",
        "author_display" => "Alice",
        "text" => "<img src=x onerror=alert(1)>"
      })

    event = Map.put(event, "occurred_at", DateTime.to_iso8601(DateTime.utc_now()))
    assert :ok = Store.ingest(Store.name("test"), event)
    conn = connection(port)
    ref = ChatOverlay.TestClient.get(conn, "/events/test", [{"last-event-id", cursor}])
    assert {:response, :nofin, 200, _} = ChatOverlay.TestClient.await(conn, ref)
    data = read_batch(conn, ref, "")
    assert data =~ "http-message"
    refute data =~ ~s("event":"reset")
    refute data =~ "other-channel"
    ChatOverlay.TestClient.close(conn)
    ChatOverlay.TestClient.close(first_conn)
  end

  test "viewer lifecycle, source crash recovery and isolation", %{port: port} do
    a = Config.profile("test")["sources"] |> hd()
    b = Config.profile("other")["sources"] |> hd()
    conn = connection(port)
    ref = ChatOverlay.TestClient.get(conn, "/events/test")
    assert {:response, :nofin, 200, _} = ChatOverlay.TestClient.await(conn, ref)
    read_batch(conn, ref, "")
    wait_until(fn -> Source.active?(a) end)
    refute Source.active?(b)
    source = GenServer.whereis(Source.name(a))
    worker = :sys.get_state(source).worker.pid
    other = GenServer.whereis(Source.name(b))
    Process.exit(source, :kill)
    wait_until(fn -> GenServer.whereis(Source.name(a)) not in [nil, source] end)
    wait_until(fn -> Source.active?(a) end)
    refute Process.alive?(worker)
    assert GenServer.whereis(Source.name(b)) == other
    ChatOverlay.TestClient.close(conn)
    wait_until(fn -> not Source.active?(a) end)
  end

  test "rendering uses text nodes and no external scripts", %{port: port} do
    {200, _, js} = request(port, "GET", "/assets/app.js")
    assert js =~ "textContent"
    refute js =~ "innerHTML"
    refute js =~ "eval("
    assert {:ok, _} = JSON.decode(~s({"ok":true}))
  end

  defp read_batch(conn, ref, acc) do
    if String.contains?(acc, "event: batch") and String.ends_with?(acc, "\n\n") do
      acc
    else
      assert {:data, :nofin, data} = ChatOverlay.TestClient.await(conn, ref, 5000)
      read_batch(conn, ref, acc <> data)
    end
  end

  defp wait_until(fun, left \\ 2000)
  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, left) do
    if not fun.() do
      Process.sleep(10)
      wait_until(fun, left - 1)
    end
  end
end
