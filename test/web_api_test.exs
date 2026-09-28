defmodule ChatOverlay.WebAPITest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias ChatOverlay.{Config, JSON, Web}

  setup do
    original_profiles = Application.get_env(:chat_overlay, :profiles, [])

    on_exit(fn ->
      Application.put_env(:chat_overlay, :profiles, original_profiles)
    end)

    Application.put_env(:chat_overlay, :profiles, [])
    :ok
  end

  test "GET /api/profiles returns JSON array of active profiles" do
    demo_profile = %{
      "handle" => "streamer-one",
      "sources" => [
        %{"platform" => "twitch", "channel" => "123", "mode" => "demo"}
      ]
    }

    Application.put_env(:chat_overlay, :profiles, [demo_profile])

    conn = conn(:get, "/api/profiles") |> Web.call([])
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]

    assert {:ok, %{"profiles" => [profile]}} = JSON.decode(conn.resp_body)
    assert profile["handle"] == "streamer-one"
    assert profile["platforms"] == ["twitch"]
    assert profile["reader_url"] == "/reader/streamer-one"
    assert profile["overlay_url"] == "/overlay/streamer-one"
  end

  test "POST /api/profiles dynamically creates a profile and starts its store" do
    payload = %{
      "handle" => "dynamic-streamer",
      "sources" => [
        %{"platform" => "twitch", "channel" => "789", "mode" => "demo"}
      ]
    }

    conn =
      conn(:post, "/api/profiles", JSON.encode(payload))
      |> put_req_header("content-type", "application/json")
      |> Web.call([])

    assert conn.status == 201
    assert {:ok, resp} = JSON.decode(conn.resp_body)
    assert resp["ok"] == true
    assert resp["reader_url"] == "/reader/dynamic-streamer"
    assert resp["overlay_url"] == "/overlay/dynamic-streamer"

    assert Config.profile("dynamic-streamer") != nil
    assert [{store_pid, _}] = Registry.lookup(ChatOverlay.Registry, {:store, "dynamic-streamer"})
    assert Process.alive?(store_pid)

    # Deleting the profile
    del_conn = conn(:delete, "/api/profiles/dynamic-streamer") |> Web.call([])
    assert del_conn.status == 200
    assert {:ok, %{"ok" => true}} = JSON.decode(del_conn.resp_body)

    assert Config.profile("dynamic-streamer") == nil
    assert Registry.lookup(ChatOverlay.Registry, {:store, "dynamic-streamer"}) == []
  end

  test "POST /api/profiles handles validation errors gracefully" do
    payload = %{
      "handle" => "INVALID HANDLE SPACES!",
      "sources" => [
        %{"platform" => "twitch", "channel" => "789", "mode" => "demo"}
      ]
    }

    conn =
      conn(:post, "/api/profiles", JSON.encode(payload))
      |> put_req_header("content-type", "application/json")
      |> Web.call([])

    assert conn.status == 422
    assert {:ok, resp} = JSON.decode(conn.resp_body)
    assert resp["ok"] == false
    assert is_binary(resp["error"])
  end

  test "DELETE /api/profiles/:handle returns 404 for nonexistent profile" do
    conn = conn(:delete, "/api/profiles/ghost") |> Web.call([])
    assert conn.status == 404
    assert {:ok, resp} = JSON.decode(conn.resp_body)
    assert resp["ok"] == false
    assert resp["error"] == "Perfil no encontrado"
  end
end
