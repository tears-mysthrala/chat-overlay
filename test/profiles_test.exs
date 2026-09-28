defmodule ChatOverlay.ProfilesTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Config, Profiles}

  setup do
    original_profiles = Application.get_env(:chat_overlay, :profiles, [])
    original_path = Application.get_env(:chat_overlay, :profiles_path)

    tmp_path =
      Path.join(System.tmp_dir!(), "profiles-test-#{System.unique_integer([:positive])}.json")

    Application.put_env(:chat_overlay, :profiles_path, tmp_path)

    on_exit(fn ->
      File.rm(tmp_path)

      case original_path do
        nil -> Application.delete_env(:chat_overlay, :profiles_path)
        path -> Application.put_env(:chat_overlay, :profiles_path, path)
      end

      current_handles = Enum.map(ChatOverlay.Config.profiles(), & &1["handle"])

      for h <- current_handles do
        _ = Profiles.delete(h)
      end

      Application.put_env(:chat_overlay, :profiles, original_profiles)
    end)

    Application.put_env(:chat_overlay, :profiles, [])
    :ok
  end

  test "slugify normalizes handles and removes illegal characters" do
    assert Profiles.slugify("Revenant") == "revenant"
    assert Profiles.slugify("@HAKODATELIVECAMERA") == "hakodatelivecamera"
    assert Profiles.slugify("Canal de Prueba (Multi-Stream)") == "canal-de-prueba-multi-stream"
    assert Profiles.slugify("---test---") == "test"
    assert Profiles.slugify("123-abc") == "123-abc"
  end

  test "list formats active profiles without exposing secrets" do
    sample = [
      %{
        "handle" => "streamer1",
        "sources" => [
          %{
            "platform" => "twitch",
            "channel" => "12345",
            "client_id" => "secret-client",
            "user_id" => "secret-user",
            "credential_env" => "CHAT_TWITCH_TOKEN"
          }
        ]
      }
    ]

    Application.put_env(:chat_overlay, :profiles, sample)
    [item] = Profiles.list()

    assert item["handle"] == "streamer1"
    assert item["platforms"] == ["twitch"]
    assert item["reader_url"] == "/reader/streamer1"
    assert item["overlay_url"] == "/overlay/streamer1"

    [source_summary] = item["sources"]
    assert source_summary["platform"] == "twitch"
    assert source_summary["channel"] == "12345"
    refute Map.has_key?(source_summary, "client_id")
    refute Map.has_key?(source_summary, "credential_env")
  end

  test "create_or_update adds a profile and delete removes it" do
    demo_source = %{
      "platform" => "twitch",
      "channel" => "111",
      "mode" => "demo"
    }

    params = %{
      "handle" => "demo-streamer",
      "sources" => [demo_source]
    }

    assert {:ok, profile} = Profiles.create_or_update(params)
    assert profile["handle"] == "demo-streamer"
    assert Config.profile("demo-streamer") != nil
    assert Profiles.get("demo-streamer") != nil

    assert :ok = Profiles.delete("demo-streamer")
    assert Config.profile("demo-streamer") == nil
    assert Profiles.get("demo-streamer") == nil
  end

  test "create_or_update merges sources from multiple platforms for the same streamer" do
    twitch_src = %{
      "platform" => "twitch",
      "channel" => "111",
      "mode" => "demo"
    }

    youtube_src = %{
      "platform" => "youtube",
      "channel" => "222",
      "mode" => "demo"
    }

    assert {:ok, _} =
             Profiles.create_or_update(%{"handle" => "multistream", "sources" => [twitch_src]})

    p1 = Config.profile("multistream")
    assert length(p1["sources"]) == 1

    assert {:ok, _} =
             Profiles.create_or_update(%{"handle" => "multistream", "sources" => [youtube_src]})

    p2 = Config.profile("multistream")
    assert length(p2["sources"]) == 2
    assert Enum.map(p2["sources"], & &1["platform"]) |> Enum.sort() == ["twitch", "youtube"]
  end

  test "hot child supervision dynamically starts Store and Source processes" do
    demo_source = %{
      "platform" => "twitch",
      "channel" => "999",
      "mode" => "demo"
    }

    assert {:ok, _} =
             Profiles.create_or_update(%{"handle" => "live-streamer", "sources" => [demo_source]})

    assert [{store_pid, _}] = Registry.lookup(ChatOverlay.Registry, {:store, "live-streamer"})
    assert Process.alive?(store_pid)

    key = Config.key(demo_source)
    assert [{source_pid, _}] = Registry.lookup(ChatOverlay.Registry, {:source, key})
    assert Process.alive?(source_pid)

    assert :ok = Profiles.delete("live-streamer")
    assert Registry.lookup(ChatOverlay.Registry, {:store, "live-streamer"}) == []
    assert Registry.lookup(ChatOverlay.Registry, {:source, key}) == []
  end

  test "create_or_update fails on invalid handles" do
    assert {:error, :invalid_handle} =
             Profiles.create_or_update(%{
               "handle" => "INVALID HANDLE WITH SPACES!",
               "sources" => [%{"platform" => "twitch", "channel" => "1", "mode" => "demo"}]
             })
  end

  test "delete returns :not_found for unknown handles" do
    assert {:error, :not_found} = Profiles.delete("nonexistent-handle")
  end

  test "concurrent profile mutations serialize cleanly without losing updates" do
    tasks =
      for i <- 1..5 do
        Task.async(fn ->
          handle = "concurrent-#{i}"
          source = %{"platform" => "twitch", "channel" => "#{100 + i}", "mode" => "demo"}
          Profiles.create_or_update(%{"handle" => handle, "sources" => [source]})
        end)
      end

    results = Task.await_many(tasks)
    assert Enum.all?(results, &match?({:ok, _}, &1))

    profiles = Config.profiles()
    assert length(profiles) == 5

    for i <- 1..5 do
      assert Config.profile("concurrent-#{i}") != nil
    end
  end

  test "create_or_update preserves linked_youtube and list/0 exposes it" do
    demo_source = %{"platform" => "twitch", "channel" => "111", "mode" => "demo"}

    params = %{
      "handle" => "streamer-linked",
      "sources" => [demo_source],
      "linked_youtube" => "https://www.youtube.com/@CanalPrueba"
    }

    assert {:ok, profile} = Profiles.create_or_update(params)
    assert profile["linked_youtube"] == "https://www.youtube.com/@CanalPrueba"

    [summary] = Profiles.list()
    assert summary["linked_youtube"] == "https://www.youtube.com/@CanalPrueba"

    assert :ok = Profiles.delete("streamer-linked")
  end

  test "sync_youtube handles errors gracefully" do
    assert {:error, :not_found} = Profiles.sync_youtube("unknown-streamer")

    demo_source = %{"platform" => "twitch", "channel" => "222", "mode" => "demo"}

    assert {:ok, _} =
             Profiles.create_or_update(%{"handle" => "no-yt", "sources" => [demo_source]})

    assert {:error, :no_linked_youtube} = Profiles.sync_youtube("no-yt")
    assert :ok = Profiles.delete("no-yt")
  end
end
