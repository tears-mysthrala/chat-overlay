defmodule ChatOverlay.DeletionAcceptanceTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias ChatOverlay.{Config, JSON, MediaCleanup, Profiles, Reauthentication, Session, Web}

  setup do
    keys = [
      :profiles,
      :profiles_path,
      :media_objects,
      :oauth_origin,
      :media_coordinator_client,
      :twitch_client_id,
      :twitch_client_secret
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:chat_overlay, &1)})
    dir = Path.join(System.tmp_dir!(), "delete-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    path = Path.join(dir, "profiles.json")
    Application.put_env(:chat_overlay, :profiles_path, path)
    Application.put_env(:chat_overlay, :oauth_origin, "https://overlay.example.test")
    Application.put_env(:chat_overlay, :media_objects, [])
    Application.put_env(:chat_overlay, :profiles, [])

    sessions =
      Map.new(["delete-alice", "delete-bob"], fn handle ->
        {:ok, _} =
          Profiles.create_or_update(%{
            "handle" => handle,
            "sources" => [%{"platform" => "twitch", "channel" => handle, "mode" => "demo"}]
          })

        {:ok, p} =
          Profiles.link_account(handle, "twitch", %{username: handle, user_id: handle}, %{
            "access_token" => "synthetic",
            "expires_in" => 3600
          })

        {:ok, token} =
          Session.create_token(%{
            "handle" => handle,
            "provider" => "twitch",
            "user_id" => handle,
            "account_version" => p["linked_accounts"]["twitch"]["account_version"]
          })

        {handle, token}
      end)

    secret = NimbleTOTP.secret()
    factor_path = Path.join(dir, "factors.json")

    File.write!(
      factor_path,
      JSON.encode([
        %{
          "handle" => "delete-alice",
          "provider" => "twitch",
          "user_id" => "delete-alice",
          "secret" => Base.encode32(secret, padding: false)
        }
      ])
    )

    File.chmod!(factor_path, 0o600)
    {:ok, clock} = Agent.start_link(fn -> 1_800_000_001 end)

    {:ok, factor_state} =
      Reauthentication.init(path: factor_path, clock: fn -> Agent.get(clock, & &1) end)

    original_factor = :sys.get_state(Reauthentication)
    :sys.replace_state(Reauthentication, fn _ -> factor_state end)
    Agent.update(clock, fn _ -> 1_800_000_031 end)

    on_exit(fn ->
      :sys.replace_state(Reauthentication, fn _ -> original_factor end)
      Application.put_env(:chat_overlay, :profiles_path, path)
      for handle <- ["delete-alice", "delete-bob"], do: Profiles.delete(handle)

      Enum.each(previous, fn
        {k, {:ok, v}} -> Application.put_env(:chat_overlay, k, v)
        {k, :error} -> Application.delete_env(:chat_overlay, k)
      end)

      File.rm_rf!(dir)
    end)

    %{secret: secret, clock: clock, sessions: sessions, path: path, dir: dir}
  end

  test "HTTP deletion revokes sessions/capability, closes readers and stops only A's workers",
       c do
    {:ok, capability, _} = Profiles.regenerate_capability_token("delete-alice")
    bob = Config.profile("delete-bob")
    [{store, _}] = Registry.lookup(ChatOverlay.Registry, {:store, "delete-alice"})
    source = hd(Config.profile("delete-alice")["sources"])
    [{source_pid, _}] = Registry.lookup(ChatOverlay.Registry, {:source, Config.key(source)})
    store_ref = Process.monitor(store)
    source_ref = Process.monitor(source_pid)
    Registry.register(ChatOverlay.SSERegistry, "delete-alice", :reader)
    response = delete(c, "delete-alice")
    assert response.status == 200
    assert response.resp_cookies[Session.cookie_name()].max_age == 0
    assert Session.revoked?(c.sessions["delete-alice"])
    assert_receive {:profile_deleted, "delete-alice"}
    assert_receive {:DOWN, ^store_ref, :process, ^store, _}
    assert_receive {:DOWN, ^source_ref, :process, ^source_pid, _}
    assert Config.profile("delete-alice") == nil
    assert Config.profile("delete-bob") == bob
    assert {:error, _} = Profiles.verify_capability_token("delete-alice", capability)

    assert {:error, :unauthorized} =
             Session.authorize(connection(c, "delete-alice"), "delete-alice")

    assert :ok = Session.authorize(connection(c, "delete-bob"), "delete-bob")
    assert {:error, :not_found} = ChatOverlay.Tokens.get_access_token("delete-alice", "twitch")
    assert Enum.map(Config.load_document!(c.path)["profiles"], & &1["handle"]) == ["delete-bob"]
  end

  test "SSO, wrong code, other profile and wrong origin cannot delete", c do
    assert Web.call(connection(c, "delete-alice"), []).status == 403
    assert delete(c, "delete-alice", "xxxxxx").status == 403

    assert connection(c, "delete-alice")
           |> Map.put(:path_info, ["api", "profiles", "delete-bob"])
           |> Web.call([])
           |> Map.get(:status) == 403

    assert connection(c, "delete-alice")
           |> put_req_header("origin", "https://attacker.example")
           |> put_req_header("x-reauth-code", code(c))
           |> Web.call([])
           |> Map.get(:status) == 403

    assert Config.profile("delete-alice") != nil
    assert Config.profile("delete-bob") != nil
  end

  test "disk failure preserves access and requires a new code for retry", c do
    before = Config.profile("delete-alice")

    Application.put_env(
      :chat_overlay,
      :profiles_path,
      Path.join([c.dir, "missing", "profiles.json"])
    )

    assert delete(c, "delete-alice").status == 422
    assert Config.profile("delete-alice") == before
    Application.put_env(:chat_overlay, :profiles_path, c.path)
    assert delete(c, "delete-alice").status == 403
    Agent.update(c.clock, &(&1 + 30))
    assert delete(c, "delete-alice").status == 200
  end

  test "revocation queued before DELETE is checked before consuming the factor", c do
    writer = Process.whereis(Profiles)
    :ok = :sys.suspend(writer)

    try do
      revoke = Task.async(fn -> Session.revoke_token(c.sessions["delete-alice"]) end)
      assert queued?(writer, 1)
      deletion = Task.async(fn -> delete(c, "delete-alice") end)
      assert queued?(writer, 2)
      :ok = :sys.resume(writer)
      assert :ok = Task.await(revoke)
      assert Task.await(deletion).status == 403
      assert Config.profile("delete-alice") != nil
      # A rejected session did not consume a usable factor.
      assert :ok =
               Reauthentication.consume(
                 %{
                   "handle" => "delete-alice",
                   "provider" => "twitch",
                   "user_id" => "delete-alice"
                 },
                 code(c)
               )
    after
      :sys.resume(writer)
    end
  end

  test "deletion cancels a blocked token refresh without affecting B", c do
    owner = self()
    Application.put_env(:chat_overlay, :twitch_client_id, "synthetic-client")
    Application.put_env(:chat_overlay, :twitch_client_secret, "synthetic-secret")

    http_client = fn :post, _, _, _ ->
      send(owner, {:refresh_started, self()})

      receive do
        :release -> {:error, :unexpected_resume}
      after
        10_000 -> {:error, :fixture_timeout}
      end
    end

    {:ok, profile} =
      Profiles.link_account(
        "delete-alice",
        "twitch",
        %{username: "delete-alice", user_id: "delete-alice"},
        %{
          "access_token" => "expired-synthetic",
          "refresh_token" => "synthetic-refresh",
          "expires_in" => -1
        }
      )

    {:ok, token} =
      Session.create_token(%{
        "handle" => "delete-alice",
        "provider" => "twitch",
        "user_id" => "delete-alice",
        "account_version" => profile["linked_accounts"]["twitch"]["account_version"]
      })

    c = %{c | sessions: Map.put(c.sessions, "delete-alice", token)}

    pending =
      Task.async(fn ->
        ChatOverlay.Tokens.get_access_token("delete-alice", "twitch", http_client: http_client)
      end)

    assert_receive {:refresh_started, worker}, 2_000
    monitor = Process.monitor(worker)
    assert delete(c, "delete-alice").status == 200
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert {:error, reason} = Task.await(pending)
    assert reason in [:binding_invalidated, :stale_binding, :not_found]
    assert Config.profile("delete-bob") != nil
  end

  test "cleanup survives reload and failed remote deletion without false success", c do
    object = %{
      "handle" => "delete-alice",
      "key" => "delete-alice/synthetic.png",
      "size" => 100,
      "category" => "image",
      "mime" => "image/png",
      "expires_at" => 1,
      "state" => "pending",
      "bucket" => "quarantine"
    }

    Application.put_env(:chat_overlay, :media_objects, [object])
    assert delete(c, "delete-alice").status == 200
    doc = Config.load_document!(c.path)
    assert [%{"state" => "retired"}] = doc["media_objects"]
    Application.put_env(:chat_overlay, :media_objects, doc["media_objects"])

    Application.put_env(:chat_overlay, :media_coordinator_client, fn "/delete", _ ->
      {:error, :unavailable}
    end)

    assert {:error, :storage_cleanup_failed} = MediaCleanup.sweep_one()
    assert length(Profiles.media_objects()) == 1

    Application.put_env(:chat_overlay, :media_coordinator_client, fn "/delete", _ ->
      {:ok, %{"state" => "deleted", "sealed" => true}}
    end)

    assert :ok = MediaCleanup.sweep_one()
    assert :ok = Profiles.cleanup_media(object["key"])
    assert Config.load_document!(c.path)["media_objects"] == []
  end

  defp code(c), do: NimbleTOTP.verification_code(c.secret, time: Agent.get(c.clock, & &1))

  defp delete(c, handle, otp \\ nil),
    do: connection(c, handle) |> put_req_header("x-reauth-code", otp || code(c)) |> Web.call([])

  defp connection(c, handle) do
    conn(:delete, "/api/profiles/" <> handle)
    |> Map.merge(%{remote_ip: {198, 51, 100, 2}, scheme: :https, host: "overlay.example.test"})
    |> put_req_header("origin", "https://overlay.example.test")
    |> put_req_cookie(Session.cookie_name(), c.sessions[handle])
  end

  defp queued?(pid, count, tries \\ 100)
  defp queued?(_, _, 0), do: false

  defp queued?(pid, count, tries) do
    if elem(Process.info(pid, :message_queue_len), 1) >= count,
      do: true,
      else:
        (
          Process.sleep(5)
          queued?(pid, count, tries - 1)
        )
  end
end
