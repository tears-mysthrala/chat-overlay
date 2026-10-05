defmodule ChatOverlay.MediaLedgerTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Config, Media, MediaCleanup, MediaLedger, Profiles}

  setup do
    names = [:profiles, :profiles_path, :media_objects, :media_http_client]
    previous = Map.new(names, &{&1, Application.fetch_env(:chat_overlay, &1)})
    dir = Path.join(System.tmp_dir!(), "media-ledger-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "profiles.json")
    Application.put_env(:chat_overlay, :profiles_path, path)
    Application.put_env(:chat_overlay, :media_objects, [])

    Application.put_env(:chat_overlay, :profiles, [
      %{
        "handle" => "ledger",
        "sources" => [%{"platform" => "twitch", "channel" => "ledger", "mode" => "demo"}],
        "can_upload" => true,
        "storage_quota_bytes" => 1_000
      }
    ])

    Application.put_env(:chat_overlay, :media_http_client, fn "DELETE", _ ->
      {:ok, 204, [], ""}
    end)

    on_exit(fn ->
      Enum.each(previous, fn
        {k, {:ok, v}} -> Application.put_env(:chat_overlay, k, v)
        {k, :error} -> Application.delete_env(:chat_overlay, k)
      end)

      File.rm_rf!(dir)
    end)

    %{path: path, dir: dir}
  end

  test "loader rejects null, duplicate and oversized inventory", %{path: path} do
    {:ok, object} = reserve(100)

    for inventory <- [nil, [object, object], List.duplicate(object, 129)] do
      File.write!(
        path,
        ChatOverlay.JSON.encode(%{"profiles" => Config.profiles(), "media_objects" => inventory})
      )

      assert_raise RuntimeError, ~r/Invalid overlay configuration/, fn ->
        Config.load_document!(path)
      end
    end
  end

  test "unusual filenames produce reloadable inventory", %{path: path} do
    {:ok, upload} =
      Media.validate_upload_request(
        %{"filename" => "..alert.mp3", "content_type" => "audio/mpeg", "size" => 100},
        0
      )

    assert {:ok, _} = Profiles.reserve_media_upload("ledger", upload)
    assert Config.load_document!(path)["media_objects"] == Profiles.media_objects()
  end

  test "concurrent reservations consume quota once and survive reload", %{path: path} do
    results =
      1..12 |> Task.async_stream(fn _ -> reserve(400) end, max_concurrency: 12) |> Enum.to_list()

    assert Enum.count(results, &match?({:ok, {:ok, _}}, &1)) == 2
    assert Enum.count(results, &match?({:ok, {:error, :quota_exceeded}}, &1)) == 10
    assert MediaLedger.total_bytes(Profiles.media_objects(), Config.profile("ledger")) == 800
    assert Config.load_document!(path)["media_objects"] == Profiles.media_objects()
    assert Profiles.get("ledger")["storage_pending_bytes"] == 800
  end

  test "disk failure does not allocate a reservation", %{dir: dir} do
    Application.put_env(
      :chat_overlay,
      :profiles_path,
      Path.join([dir, "missing", "profiles.json"])
    )

    assert {:error, {:directory_not_found, _}} = reserve(400)
    assert Profiles.media_objects() == []
  end

  test "one profile cannot consume the shared reservation inventory" do
    for _ <- 1..12, do: assert({:ok, _} = reserve(1))
    assert {:error, :profile_upload_reservations_full} = reserve(1)
    other = Map.put(Config.profile("ledger"), "handle", "other")

    {:ok, upload} =
      Media.validate_upload_request(
        %{"filename" => "alert.mp3", "content_type" => "audio/mpeg", "size" => 1},
        0
      )

    assert {:ok, _, _} =
             MediaLedger.reserve(
               Profiles.media_objects(),
               other,
               upload,
               System.system_time(:second)
             )
  end

  test "slow remote cleanup does not block unrelated profile mutations" do
    {:ok, object} = reserve(100)
    expire(object["key"])
    parent = self()

    Application.put_env(:chat_overlay, :media_http_client, fn _, _ ->
      send(parent, {:deleting, self()})

      receive do
        :finish_delete -> {:ok, 204, [], ""}
      after
        5_000 -> {:error, :timeout}
      end
    end)

    task = Task.async(fn -> Profiles.cleanup_media(object["key"]) end)
    assert_receive {:deleting, worker}, 1_000
    assert [%{"state" => "deleting"}] = Profiles.media_objects()
    mutation = Task.async(fn -> Profiles.regenerate_capability_token("ledger") end)
    assert {:ok, _, _} = Task.await(mutation, 1_000)
    send(worker, :finish_delete)
    assert :ok = Task.await(task)
  end

  test "replacement retains physical quota until confirmed remote cleanup", %{path: path} do
    {:ok, first} = reserve(400)
    {:ok, second} = reserve(400)

    assert {:ok, _} =
             Profiles.update_media("ledger", %{"alert_sound" => item(first)},
               require_reservation: true
             )

    assert {:ok, _} =
             Profiles.update_media("ledger", %{"alert_sound" => item(second)},
               require_reservation: true
             )

    assert Profiles.get("ledger")["storage_used_bytes"] == 400
    assert Profiles.get("ledger")["storage_pending_bytes"] == 400
    assert {:error, :quota_exceeded} = reserve(400)
    assert {:error, :object_not_retired} = Profiles.cleanup_media(second["key"])
    expire(first["key"])
    assert :ok = MediaCleanup.sweep_one()
    assert Enum.map(Profiles.media_objects(), & &1["key"]) == [second["key"]]
    assert Config.load_document!(path)["media_objects"] == Profiles.media_objects()
    assert {:ok, _} = reserve(400)
  end

  test "failed remote deletion keeps quota and retries", %{path: path} do
    {:ok, object} = reserve(400)
    expire(object["key"])
    Application.put_env(:chat_overlay, :media_http_client, fn _, _ -> {:ok, 503, [], ""} end)
    assert {:error, :storage_cleanup_failed} = MediaCleanup.sweep_one()
    assert length(Profiles.media_objects()) == 1
    Application.put_env(:chat_overlay, :media_http_client, fn _, _ -> {:ok, 404, [], ""} end)
    assert :ok = MediaCleanup.sweep_one()
    assert Config.load_document!(path)["media_objects"] == []
  end

  test "disk failure after remote deletion keeps durable retry state", %{dir: dir} do
    {:ok, object} = reserve(400)
    expire(object["key"])

    Application.put_env(
      :chat_overlay,
      :profiles_path,
      Path.join([dir, "missing", "profiles.json"])
    )

    assert {:error, {:directory_not_found, _}} = MediaCleanup.sweep_one()
    assert length(Profiles.media_objects()) == 1
  end

  test "deleted profiles leave cleanup inventory that reloads without account data", %{path: path} do
    {:ok, object} = reserve(400)
    assert :ok = Profiles.delete("ledger")
    doc = Config.load_document!(path)
    assert doc["profiles"] == []
    assert [%{"key" => key, "state" => "retired"}] = doc["media_objects"]
    assert key == object["key"]
    Application.put_env(:chat_overlay, :media_objects, doc["media_objects"])
    expire(key)
    assert :ok = MediaCleanup.sweep_one()
    assert Config.load_document!(path)["media_objects"] == []
  end

  test "retired reservation cannot be reactivated by stale association" do
    {:ok, object} = reserve(400)

    assert {:ok, _} =
             Profiles.update_media("ledger", %{"alert_sound" => item(object)},
               require_reservation: true
             )

    assert {:ok, _} =
             Profiles.update_media("ledger", %{"alert_sound" => nil}, require_reservation: true)

    assert {:error, :invalid_upload_token} =
             Profiles.update_media("ledger", %{"alert_sound" => item(object)},
               require_reservation: true
             )
  end

  test "permission is enforced again at reservation time" do
    Application.put_env(:chat_overlay, :profiles, [
      Map.put(Config.profile("ledger"), "can_upload", false)
    ])

    assert {:error, :uploads_not_allowed} = reserve(100)
  end

  test "revoking upload permission before association prevents activation" do
    {:ok, object} = reserve(100)

    Application.put_env(:chat_overlay, :profiles, [
      Map.put(Config.profile("ledger"), "can_upload", false)
    ])

    assert {:error, :invalid_upload_token} =
             Profiles.update_media("ledger", %{"alert_sound" => item(object)},
               require_reservation: true
             )

    assert [%{"state" => "pending"}] = Profiles.media_objects()
    assert (Config.profile("ledger")["media"] || %{}) == %{}
  end

  test "storage transport rejects arbitrary endpoints and methods before DNS" do
    assert {:error, :destination_rejected} =
             ChatOverlay.Net.storage_request("DELETE", "https://evil.example/file")

    assert {:error, :destination_rejected} =
             ChatOverlay.Net.storage_request("GET", "https://r2.example.com/file")

    assert {:error, :destination_rejected} =
             ChatOverlay.Net.storage_request("DELETE", "https://user@r2.example.com/file")
  end

  defp reserve(size) do
    {:ok, upload} =
      Media.validate_upload_request(
        %{"filename" => "alert.mp3", "content_type" => "audio/mpeg", "size" => size},
        0
      )

    Profiles.reserve_media_upload("ledger", upload)
  end

  defp item(object),
    do: %{
      "url" => "https://media.example.com/" <> object["key"],
      "source" => "r2",
      "key" => object["key"],
      "size" => object["size"]
    }

  defp expire(key) do
    Application.put_env(
      :chat_overlay,
      :media_objects,
      Enum.map(Profiles.media_objects(), fn o ->
        if o["key"] == key,
          do: Map.put(o, "expires_at", System.system_time(:second) - 60),
          else: o
      end)
    )
  end
end
