defmodule ChatOverlay.PostgresRLSTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Config, JSON, Postgres, PostgresTransfer, Profiles, ProfileStorage}
  @runtime ChatOverlay.Postgres.Runtime
  @bootstrap ChatOverlay.Postgres.Bootstrap
  @empty %{"profiles" => [], "media_objects" => []}

  setup_all do
    # Mandatory real DB: no environment-dependent exclusions/skips or mocks.
    host = System.fetch_env!("PG_LOCAL_HOST")
    common = [hostname: host, database: "overlay_synthetic", port: 5432, pool_size: 1, ssl: false]

    for {name, username, password} <- [
          {@runtime, "overlay_runtime", "synthetic-runtime"},
          {@bootstrap, "overlay_bootstrap", "synthetic-bootstrap"},
          {__MODULE__.Migrator, "overlay_migrator", "synthetic-migration"}
        ] do
      start_supervised!(
        Supervisor.child_spec(
          {Postgrex, common ++ [name: name, username: username, password: password]},
          id: name
        )
      )
    end

    :ok
  end

  setup do
    previous_profiles = Config.profiles()
    previous_objects = Profiles.media_objects()
    previous_backend = Application.fetch_env!(:chat_overlay, :persistence_backend)
    :ok = Postgres.replace(Postgres.export!(), @empty)
    seed = seed()
    :ok = Postgres.replace(@empty, seed)
    Application.put_env(:chat_overlay, :persistence_backend, :postgres)
    Application.put_env(:chat_overlay, :profiles, seed["profiles"])
    Application.put_env(:chat_overlay, :media_objects, seed["media_objects"])

    on_exit(fn ->
      Application.put_env(:chat_overlay, :persistence_backend, previous_backend)
      Application.put_env(:chat_overlay, :profiles, previous_profiles)
      Application.put_env(:chat_overlay, :media_objects, previous_objects)
    end)

    %{seed: Postgres.canonical(seed)}
  end

  test "effective runtime and bootstrap privileges, owner separation and FORCE RLS" do
    assert :ok = Postgres.validate_runtime!()
    assert :ok = Postgres.validate_bootstrap!()
    assert_raise MatchError, fn -> Postgres.validate_runtime!(@bootstrap) end
    assert %{rows: [["18.6"]]} = Postgrex.query!(@runtime, "SHOW server_version", [])

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             Postgrex.query(@runtime, "SET ROLE overlay_migrator", [])

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             Postgrex.query(@runtime, "TRUNCATE overlay.objects", [])

    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             Postgrex.query(@bootstrap, "DELETE FROM overlay.objects", [])
  end

  for table <- ["profiles", "accounts", "objects"] do
    test "#{table} denies reads/writes without context and filters cross-profile updates/deletes" do
      table = unquote(table)
      # Table names are compile-time constants, never HTTP/user identifiers.
      assert %{rows: []} = Postgrex.query!(@runtime, "SELECT handle FROM overlay.#{table}", [])

      assert {:ok, :ok} =
               Postgrex.transaction(@runtime, fn conn ->
                 context(conn, "alpha")

                 assert %{rows: [["alpha"]]} =
                          Postgrex.query!(conn, "SELECT handle FROM overlay.#{table}", [])

                 assert %{num_rows: 0} =
                          Postgrex.query!(
                            conn,
                            "UPDATE overlay.#{table} SET body=body WHERE handle=$1",
                            ["beta"]
                          )

                 assert %{num_rows: 0} =
                          Postgrex.query!(conn, "DELETE FROM overlay.#{table} WHERE handle=$1", [
                            "beta"
                          ])

                 :ok
               end)

      assert %{rows: []} = Postgrex.query!(@runtime, "SELECT handle FROM overlay.#{table}", [])
    end
  end

  for {label, sql, params} <- [
        {"profile",
         "INSERT INTO overlay.profiles(handle,body,accounts_present) VALUES($1,$2,false)",
         ["gamma", "{}"]},
        {"account", "INSERT INTO overlay.accounts(handle,provider,body) VALUES($1,'youtube',$2)",
         ["beta", "{}"]},
        {"object", "INSERT INTO overlay.objects(handle,key,body) VALUES($1,'beta/new',$2)",
         ["beta", "{}"]}
      ] do
    test "#{label} WITH CHECK rejects absent and cross-profile context" do
      sql = unquote(sql)
      params = unquote(params)

      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Postgrex.query(@runtime, sql, params)

      assert_raise Postgrex.Error, fn ->
        Postgrex.transaction(@runtime, fn conn ->
          context(conn, "alpha")
          Postgrex.query!(conn, sql, params)
        end)
      end

      assert %{rows: [[nil]]} =
               Postgrex.query!(
                 @runtime,
                 "SELECT nullif(current_setting('overlay.handle',true),'')",
                 []
               )
    end
  end

  test "WITH CHECK blocks changing an owned row to another profile" do
    for table <- ["profiles", "accounts", "objects"] do
      assert_raise Postgrex.Error, fn ->
        Postgrex.transaction(@runtime, fn conn ->
          context(conn, "alpha")

          Postgrex.query!(conn, "UPDATE overlay.#{table} SET handle=$1 WHERE handle=$2", [
            "gamma",
            "alpha"
          ])
        end)
      end
    end
  end

  test "a reused pool connection clears context on commit, rollback and exceptions", ctx do
    for outcome <- [:commit, :rollback, :exception] do
      execute = fn ->
        Postgrex.transaction(@runtime, fn conn ->
          context(conn, "alpha")

          if outcome != :commit do
            profile =
              hd(ctx.seed["profiles"])
              |> Map.delete("linked_accounts")
              |> Map.put("storage_used_bytes", 777)

            Postgrex.query!(conn, "UPDATE overlay.profiles SET body=$1 WHERE handle=$2", [
              JSON.encode(profile),
              "alpha"
            ])
          end

          case outcome do
            :commit -> :ok
            :rollback -> Postgrex.rollback(conn, :synthetic_failure)
            :exception -> raise "synthetic failure"
          end
        end)
      end

      case outcome do
        :commit -> assert {:ok, :ok} = execute.()
        :rollback -> assert {:error, :synthetic_failure} = execute.()
        :exception -> assert_raise RuntimeError, execute
      end

      assert %{rows: []} = Postgrex.query!(@runtime, "SELECT handle FROM overlay.profiles", [])

      assert {:ok, [["beta"]]} =
               Postgrex.transaction(@runtime, fn conn ->
                 context(conn, "beta")
                 Postgrex.query!(conn, "SELECT handle FROM overlay.profiles", []).rows
               end)
    end

    assert Postgres.export!() == ctx.seed
  end

  test "stale snapshot cannot overwrite a completed write", ctx do
    assert {:ok, _} = Profiles.update_upload_quota("alpha", 1)
    assert {:error, :stale_storage} = Postgres.replace(ctx.seed, @empty)
    assert hd(Postgres.export!()["profiles"])["storage_used_bytes"] == 1
  end

  test "HTTP derives scope from a verified session, ignoring another handle" do
    {:ok, token} =
      ChatOverlay.Session.create_token(%{
        "handle" => "alpha",
        "provider" => "twitch",
        "user_id" => "synthetic-alpha",
        "account_version" => 7
      })

    conn =
      Plug.Test.conn(:post, "/api/profiles/beta/token/regenerate")
      |> Plug.Conn.put_req_header("cookie", ChatOverlay.Session.cookie_name() <> "=" <> token)

    before = Postgres.export!()
    assert ChatOverlay.Web.call(conn, []).status == 403
    assert Postgres.export!() == before

    own =
      Plug.Test.conn(:post, "/api/profiles/alpha/token/regenerate")
      |> Plug.Conn.put_req_header("cookie", ChatOverlay.Session.cookie_name() <> "=" <> token)

    assert ChatOverlay.Web.call(own, []).status == 200
    refute Postgres.export!() == before
    assert Enum.at(Postgres.export!()["profiles"], 1) == Enum.at(before["profiles"], 1)
  end

  test "failure after profile/account/object mutations rolls the entire transaction back", ctx do
    Postgrex.query!(
      __MODULE__.Migrator,
      "REVOKE INSERT ON overlay.accounts FROM overlay_runtime",
      []
    )

    try do
      assert {:error, :database_unavailable} = Profiles.update_upload_quota("alpha", 42)
      assert Postgres.export!() == ctx.seed
      assert Postgres.canonical(runtime_document()) == ctx.seed
      assert %{rows: []} = Postgrex.query!(@runtime, "SELECT handle FROM overlay.accounts", [])
    after
      Postgrex.query!(
        __MODULE__.Migrator,
        "GRANT INSERT ON overlay.accounts TO overlay_runtime",
        []
      )
    end
  end

  test "unverified request and authorized A cannot mutate B; request scope clears on exception",
       ctx do
    assert {:error, :database_unavailable} =
             ChatOverlay.RequestScope.request(fn -> Profiles.update_upload_quota("alpha", 1) end)

    assert {:error, :database_unavailable} =
             ChatOverlay.RequestScope.with_scope({:profile, "alpha"}, fn ->
               Profiles.update_upload_quota("beta", 1)
             end)

    assert_raise RuntimeError, fn ->
      ChatOverlay.RequestScope.request(fn -> raise "synthetic" end)
    end

    assert ChatOverlay.RequestScope.current() == :service
    assert Postgres.export!() == ctx.seed
  end

  test "product reserve and cleanup persist ledger without contacting real R2" do
    upload = %{key: "local-reservation.png", size: 100, category: :image, mime: "image/png"}
    assert {:ok, object} = Profiles.reserve_media_upload("alpha", upload)
    assert object in Postgres.export!()["media_objects"]
    before = runtime_document()

    objects =
      Enum.map(before["media_objects"], fn o ->
        if o == object, do: Map.put(o, "expires_at", 1), else: o
      end)

    assert :ok = Postgres.replace(before, Map.put(before, "media_objects", objects))
    Application.put_env(:chat_overlay, :media_objects, objects)
    previous_client = Application.get_env(:chat_overlay, :media_http_client)

    Application.put_env(:chat_overlay, :media_http_client, fn "DELETE", _ ->
      {:ok, 204, [], ""}
    end)

    try do
      assert :ok = Profiles.cleanup_media(object["key"])
      refute Enum.any?(Postgres.export!()["media_objects"], &(&1["key"] == object["key"]))
    after
      if previous_client,
        do: Application.put_env(:chat_overlay, :media_http_client, previous_client),
        else: Application.delete_env(:chat_overlay, :media_http_client)
    end
  end

  test "real product mutations persist accounts, ciphertext, versions, capabilities and ledger" do
    assert {:ok, _} =
             Profiles.create_or_update(%{"handle" => "gamma", "sources" => [source("gamma")]})

    assert {:ok, _} =
             Profiles.link_account("gamma", "twitch", %{user_id: "synthetic-gamma"}, %{
               "access_token" => "synthetic-token"
             })

    assert {:ok, _} =
             Profiles.update_tokens("gamma", "twitch", %{"access_token" => "synthetic-new-token"})

    assert {:ok, _, _} = Profiles.regenerate_capability_token("gamma")

    assert {:ok, _} =
             Profiles.update_media("gamma", %{
               "alert_sound" => %{
                 "source" => "external",
                 "url" => "https://example.com/audio.mp3"
               }
             })

    assert Postgres.export!() == Postgres.canonical(runtime_document())
    assert {:ok, _} = Profiles.unlink_account("gamma", "twitch")
    assert :ok = Profiles.delete("gamma")
    assert :ok = Profiles.delete("alpha")

    assert [%{"state" => "retired"}] =
             Enum.filter(Postgres.export!()["media_objects"], &(&1["handle"] == "alpha"))

    assert Postgres.export!() == Postgres.canonical(runtime_document())
  end

  for operation <- [:create, :update, :delete, :token, :media, :quota, :link, :unlink] do
    test "#{operation} database failure preserves durable and runtime state without JSON fallback" do
      before = runtime_document()

      Postgrex.query!(
        __MODULE__.Migrator,
        "REVOKE INSERT, UPDATE, DELETE ON overlay.profiles,overlay.accounts,overlay.objects FROM overlay_runtime",
        []
      )

      try do
        assert {:error, :database_unavailable} = mutate(unquote(operation))
        assert runtime_document() == before
        assert Postgres.export!() == Postgres.canonical(before)
      after
        Postgrex.query!(
          __MODULE__.Migrator,
          "GRANT INSERT, UPDATE, DELETE ON overlay.profiles,overlay.accounts,overlay.objects TO overlay_runtime",
          []
        )
      end
    end
  end

  test "serialized concurrent product mutations and restart loader match durable storage" do
    results =
      1..20
      |> Task.async_stream(fn _ -> Profiles.update_upload_quota("alpha", 1) end,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert Config.profile("alpha")["storage_used_bytes"] == 20
    stored = Postgres.export!()
    Application.put_env(:chat_overlay, :profiles, [])
    Application.put_env(:chat_overlay, :media_objects, [])
    start_supervised!(ChatOverlay.Persistence.Loader)
    assert runtime_document() == stored
  end

  test "offline copy migration and post-write rollback export preserve exact private data", ctx do
    dir = Path.join(System.tmp_dir!(), "postgres-transfer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    source = Path.join(dir, "offline-copy.json")
    target = Path.join(dir, "post-write-rollback.json")
    assert :ok = ProfileStorage.write(source, ctx.seed["profiles"], ctx.seed["media_objects"])
    original = File.read!(source)
    assert_raise MatchError, fn -> PostgresTransfer.import_copy!(source) end
    assert :ok = Postgres.replace(ctx.seed, @empty)
    assert %{digest: digest} = PostgresTransfer.import_copy!(source)
    assert digest == Postgres.digest(ctx.seed)
    assert File.read!(source) == original
    assert {:ok, _} = Profiles.update_upload_quota("alpha", 123)
    assert %{digest: updated_digest} = PostgresTransfer.export_copy!(target)
    refute updated_digest == digest
    assert Postgres.canonical(Config.load_document!(target)) == Postgres.export!()
    assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o600
    assert_raise MatchError, fn -> PostgresTransfer.export_copy!(target) end
    assert File.read!(source) == original
  end

  defp context(conn, handle),
    do: Postgrex.query!(conn, "SELECT set_config('overlay.handle',$1,true)", [handle])

  defp source(handle), do: %{"platform" => "twitch", "channel" => handle, "mode" => "demo"}

  defp runtime_document,
    do: %{"profiles" => Config.profiles(), "media_objects" => Profiles.media_objects()}

  defp seed do
    profiles =
      for handle <- ["alpha", "beta"] do
        {:ok, ciphertext} =
          ChatOverlay.Crypto.encrypt_aead(
            JSON.encode(%{"access_token" => "synthetic-#{handle}"}),
            ChatOverlay.OAuth.encryption_key(),
            "token:#{handle}:twitch"
          )

        %{
          "handle" => handle,
          "sources" => [source(handle)],
          "can_upload" => true,
          "capability_token_hash" => ChatOverlay.Crypto.hash_token("synthetic-#{handle}"),
          "linked_accounts" => %{
            "twitch" => %{
              "user_id" => "synthetic-#{handle}",
              "account_version" => 7,
              "encrypted_tokens" => ciphertext
            }
          },
          "storage_used_bytes" => 0
        }
      end

    objects =
      for handle <- ["alpha", "beta"],
          do: %{
            "handle" => handle,
            "key" => handle <> "/synthetic.png",
            "size" => 128,
            "category" => "image",
            "mime" => "image/png",
            "expires_at" => 4_000_000_000,
            "state" => "pending"
          }

    %{"profiles" => profiles, "media_objects" => objects}
  end

  defp mutate(:create),
    do: Profiles.create_or_update(%{"handle" => "gamma", "sources" => [source("gamma")]})

  defp mutate(:update),
    do: Profiles.create_or_update(%{"handle" => "alpha", "sources" => [source("replacement")]})

  defp mutate(:delete), do: Profiles.delete("alpha")
  defp mutate(:token), do: Profiles.regenerate_capability_token("alpha")

  defp mutate(:media),
    do:
      Profiles.update_media("alpha", %{
        "alert_sound" => %{"source" => "external", "url" => "https://example.com/audio.mp3"}
      })

  defp mutate(:quota), do: Profiles.update_upload_quota("alpha", 1)

  defp mutate(:link),
    do:
      Profiles.link_account("alpha", "twitch", %{user_id: "synthetic"}, %{
        "access_token" => "synthetic"
      })

  defp mutate(:unlink), do: Profiles.unlink_account("alpha", "twitch")
end
