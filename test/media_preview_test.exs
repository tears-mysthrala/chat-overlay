defmodule ChatOverlay.MediaPreviewTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{MediaPreview, Store, Web, Session, Profiles}

  setup do
    names = [:media_storage, :oauth_origin, :profiles, :media_objects, :port]
    previous = Map.new(names, &{&1, Application.fetch_env(:chat_overlay, &1)})
    Application.put_env(:chat_overlay, :media_storage, "local")
    Application.put_env(:chat_overlay, :oauth_origin, "https://overlay.example.test")

    on_exit(fn ->
      Enum.each(previous, fn
        {k, {:ok, v}} -> Application.put_env(:chat_overlay, k, v)
        {k, :error} -> Application.delete_env(:chat_overlay, k)
      end)
    end)

    key =
      "creator/validated/" <>
        String.duplicate("a", 32) <> "/" <> String.duplicate("b", 64) <> ".png"

    object = %{
      "handle" => "creator",
      "key" => key,
      "state" => "active",
      "bucket" => "public",
      "backend" => "local",
      "category" => "image",
      "mime" => "image/png",
      "size" => 100,
      "output_sha256" => String.duplicate("b", 64)
    }

    profile = %{
      "handle" => "creator",
      "capability_token_hash" => "configured",
      "media" => %{
        "alert_image" => %{
          "source" => "local",
          "key" => key,
          "size" => 100,
          "url" => "https://overlay.example.test/media/local/" <> key
        }
      }
    }

    %{object: object, profile: profile, key: key}
  end

  test "only current active normalized objects of the same owner", c do
    assert {:ok, %{"image_url" => url}} = MediaPreview.payload(c.profile, [c.object])
    assert url == "/media/local/" <> c.key

    for replacement <- [
          Map.put(c.object, "handle", "other"),
          Map.put(c.object, "state", "retired"),
          Map.put(c.object, "bucket", "quarantine"),
          Map.put(c.object, "mime", "image/gif"),
          Map.put(c.object, "backend", "r2")
        ] do
      assert {:error, _} = MediaPreview.payload(c.profile, [replacement])
    end

    assert {:error, _} = MediaPreview.payload(c.profile, [])

    assert {:error, _} =
             MediaPreview.payload(
               %{
                 "handle" => "creator",
                 "media" => %{
                   "alert_image" => %{
                     "source" => "external",
                     "url" => "https://attacker.test/image.png"
                   }
                 }
               },
               [c.object]
             )
  end

  test "preview is bounded, expires, and never enters replay or reconnect snapshot" do
    store = start_supervised!(%{id: Store, start: {Store, :start_link, [[sources: []]]}})
    assert {0, nil} = Store.preview_since(store, nil)
    assert :ok = Store.preview(store, %{"version" => 1, "image_url" => "/media/local/test.png"})
    assert {1, event} = Store.preview_since(store, 0)
    assert is_binary(event["id"])
    assert event["expires_at"] > System.system_time(:millisecond)
    assert {1, nil} = Store.preview_since(store, nil)
    assert {1, nil} = Store.preview_since(store, 1)
    assert {:error, :cooldown} = Store.preview(store, %{})
    assert Enum.all?(Store.read(store).events, &(&1["event"] in ["reset", "snapshot"]))
    :sys.replace_state(store, fn s -> %{s | preview: Map.put(s.preview, "expires_at", 0)} end)
    assert {1, nil} = Store.preview_since(store, 0)
  end

  test "anonymous requests including loopback and capability cannot publish" do
    for remote <- [{127, 0, 0, 1}, {203, 0, 113, 10}] do
      conn = Plug.Test.conn("POST", "/api/profiles/creator/media/preview?token=capability", "{}")
      conn = %{conn | remote_ip: remote}

      response =
        conn |> Plug.Conn.put_req_header("content-type", "application/json") |> Web.call([])

      assert response.status == 403
    end
  end

  test "owner can publish once, other sessions and revoked sessions cannot", c do
    profile =
      Map.put(c.profile, "linked_accounts", %{
        "twitch" => %{"user_id" => "owner", "account_version" => 1}
      })

    Application.put_env(:chat_overlay, :profiles, [profile])
    Application.put_env(:chat_overlay, :media_objects, [c.object])

    store =
      start_supervised!(%{
        id: Store,
        start: {Store, :start_link, [[name: Store.name("creator"), sources: []]]}
      })

    {:ok, token} =
      Session.create_token(%{
        "handle" => "creator",
        "provider" => "twitch",
        "user_id" => "owner",
        "account_version" => 1
      })

    request = fn token, body, origin ->
      Plug.Test.conn(
        "POST",
        "https://overlay.example.test/api/profiles/creator/media/preview",
        body
      )
      |> Plug.Test.put_req_cookie(Session.cookie_name(), token)
      |> Plug.Conn.put_req_header("origin", origin)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Web.call([])
    end

    assert request.(token, "{\"url\":\"https://attacker.test\"}", "https://overlay.example.test").status ==
             403

    assert request.(token, "{}", "https://attacker.test").status == 403

    {:ok, other} =
      Session.create_token(%{"handle" => "other", "provider" => "twitch", "user_id" => "owner"})

    assert request.(other, "{}", "https://overlay.example.test").status == 403
    assert request.(token, "{}", "https://overlay.example.test").status == 200
    assert request.(token, "{}", "https://overlay.example.test").status == 429
    assert {1, _} = Store.preview_since(store, 0)

    assert {:error, :preview_rejected} =
             Profiles.preview_media("creator", fn -> {:error, :revoked} end)

    assert {1, nil} = Store.preview_since(store, 1)
    assert :ok = Profiles.revoke_session(token, [])
    assert request.(token, "{}", "https://overlay.example.test").status == 403
  end

  test "configuration and cleanup changes during authorization reject stale media", c do
    store =
      start_supervised!(%{
        id: Store,
        start: {Store, :start_link, [[name: Store.name("creator"), sources: []]]}
      })

    for change <- [:configuration, :cleanup] do
      Application.put_env(:chat_overlay, :profiles, [c.profile])
      Application.put_env(:chat_overlay, :media_objects, [c.object])
      parent = self()

      task =
        Task.async(fn ->
          Profiles.preview_media("creator", fn ->
            send(parent, {:authorizing, self()})

            receive do
              :continue ->
                send(parent, {:authorization_resumed, change})
                :ok
            after
              2000 -> {:error, :timeout}
            end
          end)
        end)

      assert_receive {:authorizing, executor}, 2000

      case change do
        :configuration ->
          Application.put_env(:chat_overlay, :profiles, [Map.put(c.profile, "media", %{})])

        :cleanup ->
          Application.put_env(:chat_overlay, :media_objects, [
            Map.put(c.object, "state", "retired")
          ])
      end

      send(executor, :continue)
      assert_receive {:authorization_resumed, ^change}, 2000
      assert Task.await(task) == {:error, :preview_rejected}
      assert {0, nil} = Store.preview_since(store, 0)
    end
  end

  test "real SSE delivers to protected overlay once, skips reader and reconnect", c do
    token = ChatOverlay.Crypto.generate_capability_token()

    profile =
      c.profile
      |> Map.put("sources", [])
      |> Map.put("capability_token_hash", ChatOverlay.Crypto.hash_token(token))

    Application.put_env(:chat_overlay, :profiles, [profile])
    Application.put_env(:chat_overlay, :media_objects, [c.object])
    Application.put_env(:chat_overlay, :port, 0)
    start_supervised!(ChatOverlay.HTTP)

    store =
      start_supervised!(%{
        id: Store,
        start: {Store, :start_link, [[name: Store.name("creator"), sources: []]]}
      })

    connect = fn query ->
      {:ok, conn} = ChatOverlay.TestClient.open(~c"localhost", ChatOverlay.HTTP.port(), %{})
      ref = ChatOverlay.TestClient.get(conn, "/events/creator" <> query)
      assert {:response, :nofin, 200, _} = ChatOverlay.TestClient.await(conn, ref)
      {conn, ref}
    end

    {overlay, oref} = connect.("?view=overlay&token=" <> token)
    {reader, rref} = connect.("")
    {:ok, payload} = MediaPreview.payload(profile, [c.object])
    assert :ok = Store.preview(store, payload)
    data = sse_until(overlay, oref, "", "event: media_preview")
    assert data =~ c.key
    refute sse_drain(reader, rref, "") =~ "media_preview"
    ChatOverlay.TestClient.close(overlay)
    {reconnected, ref} = connect.("?view=overlay&token=" <> token)
    refute sse_drain(reconnected, ref, "") =~ "media_preview"
    assert Store.read(store).events |> Enum.all?(&(&1["event"] in ["reset", "snapshot"]))
    ChatOverlay.TestClient.close(reconnected)
    ChatOverlay.TestClient.close(reader)
  end

  defp sse_until(conn, ref, acc, marker) do
    if String.contains?(acc, marker) do
      acc
    else
      case ChatOverlay.TestClient.await(conn, ref, 2000) do
        {:data, :nofin, data} -> sse_until(conn, ref, acc <> data, marker)
        other -> flunk("SSE did not deliver preview: #{inspect(other)}")
      end
    end
  end

  defp sse_drain(conn, ref, acc) do
    case ChatOverlay.TestClient.await(conn, ref, 200) do
      {:data, :nofin, data} -> sse_drain(conn, ref, acc <> data)
      {:error, :timeout} -> acc
      other -> flunk("Unexpected SSE result: #{inspect(other)}")
    end
  end
end
