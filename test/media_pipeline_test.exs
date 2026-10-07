defmodule ChatOverlay.MediaPipelineTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Config, Media, MediaLedger, Profiles}

  setup do
    keys = [:profiles, :profiles_path, :media_objects, :media_coordinator_client]
    original = Map.new(keys, &{&1, Application.fetch_env(:chat_overlay, &1)})

    directory =
      Path.join(System.tmp_dir!(), "media-pipeline-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    Application.put_env(:chat_overlay, :profiles_path, Path.join(directory, "profiles.json"))
    Application.put_env(:chat_overlay, :media_objects, [])

    Application.put_env(:chat_overlay, :profiles, [
      %{
        "handle" => "pipeline",
        "sources" => [%{"platform" => "twitch", "channel" => "pipeline", "mode" => "demo"}],
        "can_upload" => true,
        "storage_quota_bytes" => 3_000_000
      }
    ])

    Application.put_env(
      :chat_overlay,
      :media_coordinator_client,
      &ChatOverlay.TestMediaCoordinator.request/2
    )

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:chat_overlay, key, value)
        {key, :error} -> Application.delete_env(:chat_overlay, key)
      end)

      File.rm_rf!(directory)
    end)

    {:ok, upload} =
      Media.validate_upload_request(
        %{"filename" => "sound.wav", "content_type" => "audio/wav", "size" => 100},
        0
      )

    {:ok, input} = Profiles.reserve_media_upload("pipeline", upload)

    {:ok, token} =
      Media.generate_upload_token("pipeline", input["key"], input["size"], input["category"])

    %{input: input, token: token}
  end

  test "private pending input cannot activate even with a valid token", %{input: input} do
    {:ok, url} = Media.public_url(input["key"])

    assert {:error, :invalid_upload_token} =
             Profiles.update_media(
               "pipeline",
               %{
                 "alert_sound" => %{
                   "source" => "r2",
                   "url" => url,
                   "key" => input["key"],
                   "size" => 100
                 }
               },
               require_reservation: true
             )

    assert [%{"bucket" => "quarantine", "state" => "pending"}] = Profiles.media_objects()
  end

  test "normalization and response retry allocate once and retain input cost", %{
    input: input,
    token: token
  } do
    parent = self()

    Application.put_env(:chat_overlay, :media_coordinator_client, fn path, job ->
      send(parent, :normalized)
      ChatOverlay.TestMediaCoordinator.request(path, job)
    end)

    {:ok, ready} = Profiles.validate_media_upload("pipeline", input["key"], token)
    assert_receive :normalized
    assert {:ok, retry} = Profiles.validate_media_upload("pipeline", input["key"], token)
    assert retry["key"] == ready["key"]
    refute_receive :normalized
    assert length(Profiles.media_objects()) == 2
    assert MediaLedger.total_bytes(Profiles.media_objects(), Config.profile("pipeline")) == 200

    {:ok, _} =
      Profiles.update_media(
        "pipeline",
        %{"alert_sound" => Map.drop(ready, ["state", "upload_token"])},
        require_reservation: true
      )

    assert Enum.any?(
             Profiles.media_objects(),
             &(&1["bucket"] == "public" and &1["state"] == "active")
           )
  end

  test "wrong profile report keeps reservations private and non-active", %{
    input: input,
    token: token
  } do
    Application.put_env(:chat_overlay, :media_coordinator_client, fn path, job ->
      {:ok, report} = ChatOverlay.TestMediaCoordinator.request(path, job)
      {:ok, Map.put(report, "handle", "other")}
    end)

    assert {:error, :validation_result_rejected} =
             Profiles.validate_media_upload("pipeline", input["key"], token)

    assert Enum.all?(Profiles.media_objects(), &(&1["state"] == "processing"))
    assert (Config.profile("pipeline")["media"] || %{}) == %{}
  end

  test "permission revoked during normalization blocks serialized completion", %{
    input: input,
    token: token
  } do
    parent = self()

    Application.put_env(:chat_overlay, :media_coordinator_client, fn path, job ->
      send(parent, {:normalizing, self()})

      receive do
        :finish -> ChatOverlay.TestMediaCoordinator.request(path, job)
      after
        3000 -> {:error, :timeout}
      end
    end)

    authorize = fn ->
      if Config.profile("pipeline")["can_upload"], do: :ok, else: {:error, :unauthorized}
    end

    task =
      Task.async(fn ->
        Profiles.validate_media_upload("pipeline", input["key"], token, authorize)
      end)

    assert_receive {:normalizing, worker}

    Application.put_env(:chat_overlay, :profiles, [
      Map.put(Config.profile("pipeline"), "can_upload", false)
    ])

    send(worker, :finish)
    assert {:error, :unauthorized} = Task.await(task)
    assert Enum.all?(Profiles.media_objects(), &(&1["state"] == "processing"))
  end
end
