defmodule ChatOverlay.ProfilePersistenceTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Config, Profiles, Store}

  setup do
    previous = Application.get_env(:chat_overlay, :profiles)
    previous_path = Application.get_env(:chat_overlay, :profiles_path)

    dir =
      Path.join(System.tmp_dir!(), "profile-persistence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, "profiles.json")
    Application.put_env(:chat_overlay, :profiles_path, path)
    Application.put_env(:chat_overlay, :profiles, [])
    profile = %{"handle" => "durable", "sources" => [source("original")]}
    assert {:ok, _} = Profiles.create_or_update(profile)
    assert {:ok, token, _} = Profiles.regenerate_capability_token("durable")

    on_exit(fn ->
      Application.put_env(:chat_overlay, :profiles_path, path)
      Profiles.delete("durable")
      Profiles.delete("new-profile")
      Application.put_env(:chat_overlay, :profiles, previous)

      if previous_path,
        do: Application.put_env(:chat_overlay, :profiles_path, previous_path),
        else: Application.delete_env(:chat_overlay, :profiles_path)

      File.rm_rf!(dir)
    end)

    %{dir: dir, path: path, token: token, before: Config.profiles()}
  end

  for operation <- [:create, :update, :delete, :token, :media, :quota, :link, :unlink] do
    test "#{operation} rejects a disk failure without changing runtime", ctx do
      operation = unquote(operation)

      prepare(operation)

      before = Config.profiles()
      original_file = File.read!(ctx.path)
      store = GenServer.whereis(Store.name("durable"))
      Registry.register(ChatOverlay.SSERegistry, "durable", {:overlay, ctx.token})

      Application.put_env(
        :chat_overlay,
        :profiles_path,
        Path.join([ctx.dir, "absent", "profiles.json"])
      )

      assert {:error, {:directory_not_found, _}} = mutate(operation)
      assert Config.profiles() == before
      assert File.read!(ctx.path) == original_file
      assert GenServer.whereis(Store.name("durable")) == store
      assert {:ok, _} = Profiles.verify_capability_token("durable", ctx.token)
      refute_receive {:capability_token_revoked, "durable"}, 20
    end
  end

  test "successful writes can be reloaded and have private permissions", ctx do
    assert {:ok, _} = Profiles.update_upload_quota("durable", 123)
    assert Config.load!(ctx.path) == Config.profiles()
    assert Bitwise.band(File.stat!(ctx.path).mode, 0o777) == 0o600
    assert File.ls!(ctx.dir) == ["profiles.json"]
  end

  test "rename failure preserves runtime and removes temporary files", ctx do
    target = Path.join(ctx.dir, "directory-target")
    File.mkdir!(target)
    Application.put_env(:chat_overlay, :profiles_path, target)
    assert {:error, {:persist_failed, _}} = Profiles.update_upload_quota("durable", 123)
    assert Config.profiles() == ctx.before
    assert Enum.sort(File.ls!(ctx.dir)) == ["directory-target", "profiles.json"]
  end

  test "serialized concurrent mutations survive reload", ctx do
    results =
      1..20
      |> Task.async_stream(fn _ -> Profiles.update_upload_quota("durable", 1) end,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert Config.profile("durable")["storage_used_bytes"] == 20
    assert Config.load!(ctx.path) == Config.profiles()
  end

  defp prepare(:unlink) do
    assert {:ok, _} =
             Profiles.link_account("durable", "twitch", %{user_id: "test-id"}, %{
               "access_token" => "synthetic"
             })
  end

  defp prepare(_), do: :ok

  defp source(channel), do: %{"platform" => "twitch", "channel" => channel, "mode" => "demo"}

  defp mutate(:create),
    do: Profiles.create_or_update(%{"handle" => "new-profile", "sources" => [source("new")]})

  defp mutate(:update),
    do: Profiles.create_or_update(%{"handle" => "durable", "sources" => [source("replacement")]})

  defp mutate(:delete), do: Profiles.delete("durable")
  defp mutate(:token), do: Profiles.regenerate_capability_token("durable")

  defp mutate(:media),
    do:
      Profiles.update_media("durable", %{
        "alert_sound" => %{"source" => "external", "url" => "https://example.com/audio.mp3"}
      })

  defp mutate(:quota), do: Profiles.update_upload_quota("durable", 42)

  defp mutate(:link),
    do:
      Profiles.link_account("durable", "twitch", %{user_id: "test-id"}, %{
        "access_token" => "synthetic"
      })

  defp mutate(:unlink), do: Profiles.unlink_account("durable", "twitch")
end
