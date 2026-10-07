defmodule ChatOverlay.LocalMediaTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{LocalMedia, Media, Profiles, Web}

  setup do
    names = [
      :profiles,
      :media_objects,
      :media_storage,
      :local_media_http_client,
      :oauth_origin,
      :media_coordinator_token
    ]

    previous = Map.new(names, &{&1, Application.fetch_env(:chat_overlay, &1)})
    Application.put_env(:chat_overlay, :media_storage, "local")
    Application.put_env(:chat_overlay, :oauth_origin, "https://overlay.example.test")
    Application.put_env(:chat_overlay, :media_coordinator_token, String.duplicate("a", 43))

    Application.put_env(:chat_overlay, :profiles, [
      %{
        "handle" => "creator",
        "can_upload" => true,
        "sources" => [%{"platform" => "twitch", "channel" => "creator", "mode" => "demo"}]
      }
    ])

    key = "creator/image/" <> String.duplicate("a", 32) <> "_test.png"

    object = %{
      "handle" => "creator",
      "key" => key,
      "size" => 4,
      "category" => "image",
      "mime" => "image/png",
      "expires_at" => System.system_time(:second) + 300,
      "state" => "pending",
      "bucket" => "quarantine",
      "backend" => "local"
    }

    Application.put_env(:chat_overlay, :media_objects, [object])

    on_exit(fn ->
      Enum.each(previous, fn
        {k, {:ok, v}} -> Application.put_env(:chat_overlay, k, v)
        {k, :error} -> Application.delete_env(:chat_overlay, k)
      end)
    end)

    {:ok, token} = Media.generate_upload_token("creator", key, 4, "image")
    %{key: key, token: token, object: object}
  end

  defp upload(key, token, body, remote \\ {127, 0, 0, 1}) do
    conn = Plug.Test.conn("PUT", "/api/media/upload/creator", body)
    conn = %{conn | remote_ip: remote}

    conn
    |> Plug.Conn.put_req_header("content-type", "image/png")
    |> Plug.Conn.put_req_header("x-upload-key", key)
    |> Plug.Conn.put_req_header("x-upload-token", token)
    |> Web.call([])
  end

  test "upload description puts the proof in headers, never in the URL", %{key: key} do
    assert {:ok, signed} =
             LocalMedia.upload_description(
               handle: "creator",
               key: key,
               size: 4,
               category: "image",
               content_type: "image/png"
             )

    assert signed.upload_url == "/api/media/upload/creator"
    assert signed.upload_headers["x-upload-token"] == signed.upload_token
    assert {:ok, _} = Media.verify_upload_token(signed.upload_token, "creator", key)
    assert {:error, _} = Media.verify_upload_token(signed.upload_token, "other", key)
  end

  test "only authorized exact reserved bytes reach the coordinator", %{key: key, token: token} do
    parent = self()

    Application.put_env(:chat_overlay, :local_media_http_client, fn method,
                                                                    bucket,
                                                                    actual_key,
                                                                    body,
                                                                    mime ->
      send(parent, {method, bucket, actual_key, body, mime})
      {:ok, 201, [], ""}
    end)

    assert upload(key, token, "DATA").status == 201
    assert_receive {"PUT", "quarantine", ^key, "DATA", "image/png"}

    for {proof, body, remote} <- [
          {"invalid", "DATA", {127, 0, 0, 1}},
          {token, "bad", {127, 0, 0, 1}},
          {token, "DATA", {192, 0, 2, 1}}
        ] do
      assert upload(key, proof, body, remote).status == 422
      refute_receive {"PUT", _, _, _, _}
    end
  end

  test "public route refuses originals and verifies output hash", %{key: key, object: object} do
    parent = self()

    Application.put_env(:chat_overlay, :local_media_http_client, fn _, _, _, _, _ ->
      send(parent, :read)
      {:ok, 200, [], "DATA"}
    end)

    assert Plug.Test.conn("GET", "/media/local/" <> key) |> Web.call([]) |> Map.fetch!(:status) ==
             404

    refute_receive :read

    public =
      "creator/validated/" <>
        String.duplicate("b", 32) <> "/" <> String.duplicate("c", 64) <> ".png"

    ready =
      Map.merge(object, %{
        "key" => public,
        "bucket" => "public",
        "state" => "ready",
        "output_sha256" => Base.encode16(:crypto.hash(:sha256, "DATA"), case: :lower)
      })

    Application.put_env(:chat_overlay, :media_objects, [ready])

    assert Plug.Test.conn("GET", "/media/local/" <> public) |> Web.call([]) |> Map.fetch!(:status) ==
             200

    assert_receive :read

    Application.put_env(:chat_overlay, :media_objects, [
      Map.put(ready, "output_sha256", String.duplicate("0", 64))
    ])

    assert Plug.Test.conn("GET", "/media/local/" <> public) |> Web.call([]) |> Map.fetch!(:status) ==
             404
  end

  test "backend switching refuses mixed inventory", %{object: object} do
    assert Media.configured?()
    Application.put_env(:chat_overlay, :media_objects, [Map.delete(object, "backend")])
    refute Media.configured?()
    assert Profiles.media_objects() != []
  end
end
