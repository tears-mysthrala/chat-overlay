defmodule ChatOverlay.WebAPITest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias ChatOverlay.{Config, JSON, Web}

  setup do
    original_profiles = Application.get_env(:chat_overlay, :profiles, [])
    original_path = Application.get_env(:chat_overlay, :profiles_path)

    tmp_path =
      Path.join(System.tmp_dir!(), "profiles-api-test-#{System.unique_integer([:positive])}.json")

    Application.put_env(:chat_overlay, :profiles_path, tmp_path)

    on_exit(fn ->
      File.rm(tmp_path)

      case original_path do
        nil -> Application.delete_env(:chat_overlay, :profiles_path)
        path -> Application.put_env(:chat_overlay, :profiles_path, path)
      end

      current_handles = Enum.map(ChatOverlay.Config.profiles(), & &1["handle"])

      for h <- current_handles do
        _ = ChatOverlay.Profiles.delete(h)
      end

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

  test "POST /api/profiles rejects invalid content-type with 415" do
    conn =
      conn(:post, "/api/profiles", "target=revenant")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Web.call([])

    assert conn.status == 415
    assert {:ok, resp} = JSON.decode(conn.resp_body)
    assert resp["ok"] == false
    assert resp["error"] =~ "application/json"
  end

  test "POST and DELETE reject unauthorized foreign origins with 403" do
    payload = %{"target" => "revenant"}

    conn =
      conn(:post, "/api/profiles", JSON.encode(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "https://malicious-site.example")
      |> Web.call([])

    assert conn.status == 403
    assert {:ok, resp} = JSON.decode(conn.resp_body)
    assert resp["ok"] == false
    assert resp["error"] == "Origen no permitido"

    del_conn =
      conn(:delete, "/api/profiles/revenant")
      |> put_req_header("origin", "https://malicious-site.example")
      |> Web.call([])

    assert del_conn.status == 403
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

  test "POST /api/profiles/:handle/sync-youtube rejects foreign origin and handles errors" do
    bad_conn =
      conn(:post, "/api/profiles/test/sync-youtube")
      |> put_req_header("origin", "https://malicious.example")
      |> Web.call([])

    assert bad_conn.status == 403

    conn = conn(:post, "/api/profiles/nonexistent/sync-youtube") |> Web.call([])
    assert conn.status == 422
    assert {:ok, resp} = JSON.decode(conn.resp_body)
    assert resp["ok"] == false

    {:ok, _} =
      ChatOverlay.Profiles.create_or_update(%{
        "handle" => "streamer-no-yt",
        "sources" => [%{"platform" => "twitch", "channel" => "333", "mode" => "demo"}]
      })

    conn_no_yt = conn(:post, "/api/profiles/streamer-no-yt/sync-youtube") |> Web.call([])
    assert conn_no_yt.status == 422
    assert {:ok, resp_no_yt} = JSON.decode(conn_no_yt.resp_body)
    assert resp_no_yt["ok"] == false
    assert resp_no_yt["error"] =~ "No se encontró ningún canal de YouTube vinculado"
    ChatOverlay.Profiles.delete("streamer-no-yt")
  end
end
