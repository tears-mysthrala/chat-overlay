defmodule ChatOverlay.WebF2Test do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Profiles, JSON}

  setup_all do
    Application.put_env(:chat_overlay, :port, 0)
    start_supervised!(ChatOverlay.HTTP)
    %{port: ChatOverlay.HTTP.port()}
  end

  setup do
    original_client = Application.get_env(:chat_overlay, :media_http_client)

    Application.put_env(:chat_overlay, :media_http_client, fn "HEAD", url ->
      object = Enum.find(Profiles.media_objects(), &String.contains?(url, &1["key"]))

      {:ok, 200,
       [{"content-length", to_string(object["size"])}, {"content-type", object["mime"]}], ""}
    end)

    original_profiles = Application.get_env(:chat_overlay, :profiles, [])
    original_objects = Application.get_env(:chat_overlay, :media_objects, [])
    Application.put_env(:chat_overlay, :media_objects, [])

    on_exit(fn ->
      if original_client,
        do: Application.put_env(:chat_overlay, :media_http_client, original_client),
        else: Application.delete_env(:chat_overlay, :media_http_client)

      Application.put_env(:chat_overlay, :media_objects, original_objects)
      Application.put_env(:chat_overlay, :profiles, original_profiles)
    end)

    f2_profile = %{
      "handle" => "streamer",
      "sources" => [
        %{"platform" => "twitch", "channel" => "streamer", "mode" => "demo"}
      ],
      "can_upload" => true,
      "storage_quota_bytes" => 10_485_760,
      "storage_used_bytes" => 0
    }

    streamer2_profile = %{
      "handle" => "streamer2",
      "sources" => [
        %{"platform" => "twitch", "channel" => "streamer2", "mode" => "demo"}
      ],
      "can_upload" => true,
      "storage_quota_bytes" => 10_485_760,
      "storage_used_bytes" => 0
    }

    profiles =
      original_profiles
      |> Enum.reject(&(&1["handle"] in ["streamer", "streamer2"]))
      |> Kernel.++([f2_profile, streamer2_profile])

    Application.put_env(:chat_overlay, :profiles, profiles)
    :ok
  end

  defp connection(port) do
    {:ok, conn} =
      ChatOverlay.TestClient.open(~c"localhost", port, %{retry: 0, protocols: [:http]})

    {:ok, :http} = ChatOverlay.TestClient.await_up(conn)
    conn
  end

  defp request(port, method, path, headers \\ [], body \\ "") do
    conn = connection(port)

    try do
      ref = ChatOverlay.TestClient.request(conn, method, path, headers, body)
      {:response, fin, status, headers} = ChatOverlay.TestClient.await(conn, ref)
      body = if fin == :nofin, do: elem(ChatOverlay.TestClient.await_body(conn, ref), 1), else: ""
      {status, headers, body}
    after
      ChatOverlay.TestClient.close(conn)
    end
  end

  test "overlay view enforces capability tokens when configured", %{port: port} do
    # 1. Backwards compatible: no token configured yet -> 200 OK
    {200, headers, body} = request(port, "GET", "/overlay/streamer")
    assert body =~ "Tu conversación"

    assert Enum.any?(headers, fn {k, v} -> k == "content-security-policy" and v =~ "media-src" end)

    # 2. Regenerate token
    assert {:ok, token, _} = Profiles.regenerate_capability_token("streamer")

    # 3. Access without token -> 401
    {401, _, unauthorized_body} = request(port, "GET", "/overlay/streamer")
    assert unauthorized_body =~ "401 No Autorizado"
    assert unauthorized_body =~ "Capability Token"

    # 4. Access with invalid token -> 401
    {401, _, _} = request(port, "GET", "/overlay/streamer?token=invalid_token")

    # 5. Access with valid token -> 200 OK
    {200, _, ok_body} = request(port, "GET", "/overlay/streamer?token=" <> token)
    assert ok_body =~ "Tu conversación"

    # 6. Reader view remains accessible locally without capability token
    {200, _, reader_body} = request(port, "GET", "/reader/streamer")
    assert reader_body =~ "Tu conversación"
  end

  test "token regeneration API endpoint generates new token and overlay URL", %{port: port} do
    headers = [
      {"origin", "http://localhost:#{port}"},
      {"content-type", "application/json"}
    ]

    {200, _, body} =
      request(port, "POST", "/api/profiles/streamer/token/regenerate", headers, "{}")

    assert {:ok, data} = JSON.decode(body)
    assert data["ok"] == true
    assert is_binary(data["token"])
    assert data["overlay_url"] == "/overlay/streamer?token=" <> data["token"]

    # Verify that the generated token works on /overlay/streamer
    {200, _, _} = request(port, "GET", data["overlay_url"])

    # Bad origin is rejected with 403
    bad_headers = [{"origin", "https://malicious.evil.com"}]

    {403, _, _} =
      request(port, "POST", "/api/profiles/streamer/token/regenerate", bad_headers, "{}")

    # Unknown profile returns 404
    {404, _, not_found_body} =
      request(port, "POST", "/api/profiles/unknown/token/regenerate", headers, "{}")

    assert {:ok, %{"ok" => false}} = JSON.decode(not_found_body)
  end

  test "media presign endpoint generates SigV4 presigned PUT URLs for valid media", %{port: port} do
    headers = [
      {"origin", "http://localhost:#{port}"},
      {"content-type", "application/json"}
    ]

    valid_payload =
      JSON.encode(%{
        "handle" => "streamer",
        "filename" => "alert.mp3",
        "content_type" => "audio/mpeg",
        "size" => 1024 * 100
      })

    {200, _, body} = request(port, "POST", "/api/media/presign", headers, valid_payload)
    assert {:ok, data} = JSON.decode(body)
    assert data["ok"] == true
    assert String.starts_with?(data["upload_url"], "https://")
    assert String.contains?(data["upload_url"], "X-Amz-Signature=")
    assert String.contains?(data["upload_url"], "X-Amz-Credential=")
    assert String.starts_with?(data["key"], "streamer/audio/")
    assert String.contains?(data["public_url"], data["key"])
  end

  test "upload permission and object binding reject unauthorized or mismatched media", %{
    port: port
  } do
    headers = [{"origin", "http://localhost:#{port}"}, {"content-type", "application/json"}]

    payload = %{
      "handle" => "streamer",
      "filename" => "sound.mp3",
      "content_type" => "audio/mpeg",
      "size" => 100
    }

    {200, _, body} = request(port, "POST", "/api/media/presign", headers, JSON.encode(payload))
    {:ok, signed} = JSON.decode(body)
    assert URI.decode(signed["upload_url"]) =~ "content-length;content-type;host"

    item = %{
      "source" => "r2",
      "url" => signed["public_url"],
      "key" => signed["key"],
      "size" => 100,
      "upload_token" => signed["upload_token"]
    }

    for {handle, slot, candidate} <- [
          {"streamer2", "alert_sound", item},
          {"streamer", "alert_image", item},
          {"streamer", "alert_sound", Map.put(item, "url", "https://evil.example/sound.mp3")},
          {"streamer", "alert_sound", Map.delete(item, "upload_token")}
        ] do
      {422, _, _} =
        request(
          port,
          "POST",
          "/api/profiles/#{handle}/media",
          headers,
          JSON.encode(%{slot => candidate})
        )
    end

    Application.put_env(
      :chat_overlay,
      :profiles,
      Enum.map(ChatOverlay.Config.profiles(), fn p ->
        if p["handle"] == "streamer", do: Map.put(p, "can_upload", false), else: p
      end)
    )

    {422, _, _} = request(port, "POST", "/api/media/presign", headers, JSON.encode(payload))

    {422, _, _} =
      request(
        port,
        "POST",
        "/api/profiles/streamer/media",
        headers,
        JSON.encode(%{"alert_sound" => item})
      )

    assert (ChatOverlay.Config.profile("streamer")["media"] || %{}) == %{}
  end

  test "association rejects missing or mismatched stored objects", %{port: port} do
    headers = [{"origin", "http://localhost:#{port}"}, {"content-type", "application/json"}]

    {200, _, body} =
      request(
        port,
        "POST",
        "/api/media/presign",
        headers,
        JSON.encode(%{
          "handle" => "streamer",
          "filename" => "sound.mp3",
          "content_type" => "audio/mpeg",
          "size" => 100
        })
      )

    {:ok, signed} = JSON.decode(body)

    payload =
      JSON.encode(%{
        "alert_sound" => %{
          "source" => "r2",
          "url" => signed["public_url"],
          "key" => signed["key"],
          "upload_token" => signed["upload_token"]
        }
      })

    for response <- [
          {:ok, 404, [], ""},
          {:ok, 200, [{"content-length", "999"}, {"content-type", "audio/mpeg"}], ""},
          {:ok, 200, [{"content-length", "100"}, {"content-type", "image/png"}], ""},
          {:error, :upstream_timeout}
        ] do
      Application.put_env(:chat_overlay, :media_http_client, fn "HEAD", _ -> response end)
      {422, _, _} = request(port, "POST", "/api/profiles/streamer/media", headers, payload)
      assert (ChatOverlay.Config.profile("streamer")["media"] || %{}) == %{}
      assert [%{"state" => "pending"}] = Profiles.media_objects()
    end
  end

  test "media presign rejects SVG files strictly for security (SEC-05)", %{port: port} do
    headers = [
      {"origin", "http://localhost:#{port}"},
      {"content-type", "application/json"}
    ]

    svg_payload =
      JSON.encode(%{
        "handle" => "streamer",
        "filename" => "exploit.svg",
        "content_type" => "image/svg+xml",
        "size" => 2048
      })

    {422, _, body} = request(port, "POST", "/api/media/presign", headers, svg_payload)
    assert {:ok, data} = JSON.decode(body)
    assert data["ok"] == false
    assert data["error"] =~ "SVG"
    assert data["error"] =~ "seguridad"
  end

  test "media presign rejects files exceeding category limits", %{port: port} do
    headers = [
      {"origin", "http://localhost:#{port}"},
      {"content-type", "application/json"}
    ]

    oversized_audio =
      JSON.encode(%{
        "handle" => "streamer",
        "filename" => "giant.wav",
        "content_type" => "audio/wav",
        "size" => 3 * 1024 * 1024
      })

    {422, _, body} = request(port, "POST", "/api/media/presign", headers, oversized_audio)
    assert {:ok, data} = JSON.decode(body)
    assert data["ok"] == false
    assert data["error"] =~ "máximo permitido"
  end

  test "media update endpoint updates and validates alert URLs", %{port: port} do
    headers = [
      {"origin", "http://localhost:#{port}"},
      {"content-type", "application/json"}
    ]

    update_payload =
      JSON.encode(%{
        "alert_sound" => %{
          "url" => "https://8.8.8.8/alerts/ping.ogg",
          "source" => "external"
        },
        "alert_image" => %{
          "url" => "https://8.8.8.8/alerts/badge.webp",
          "source" => "external"
        }
      })

    {200, _, body} =
      request(port, "POST", "/api/profiles/streamer/media", headers, update_payload)

    assert {:ok, data} = JSON.decode(body)
    assert data["ok"] == true
    assert data["media"]["alert_sound"]["url"] == "https://8.8.8.8/alerts/ping.ogg"
    assert data["media"]["alert_image"]["url"] == "https://8.8.8.8/alerts/badge.webp"

    # Reject non-HTTPS or prohibited extensions
    invalid_payload =
      JSON.encode(%{
        "alert_sound" => %{
          "url" => "http://insecure.com/sound.mp3",
          "source" => "external"
        }
      })

    {422, _, inv_body} =
      request(port, "POST", "/api/profiles/streamer/media", headers, invalid_payload)

    assert {:ok, %{"ok" => false, "error" => err}} = JSON.decode(inv_body)
    assert err =~ "HTTPS" or err =~ "no soportada" or err =~ "no permitido"
  end

  test "media presign returns upload_token and size, and update enforces quota fail-closed", %{
    port: port
  } do
    headers = [
      {"origin", "http://localhost:#{port}"},
      {"content-type", "application/json"}
    ]

    # 1. Presign returns upload_token and size
    presign_payload =
      JSON.encode(%{
        "handle" => "streamer",
        "filename" => "chime.mp3",
        "content_type" => "audio/mpeg",
        "size" => 100_000
      })

    {200, _, presign_body} = request(port, "POST", "/api/media/presign", headers, presign_payload)
    assert {:ok, presign_data} = JSON.decode(presign_body)
    assert presign_data["ok"] == true
    assert presign_data["size"] == 100_000
    assert is_binary(presign_data["upload_token"])

    # 2. Update media with valid upload_token computes storage_used_bytes
    update_payload =
      JSON.encode(%{
        "alert_sound" => %{
          "url" => presign_data["public_url"],
          "source" => "r2",
          "key" => presign_data["key"],
          "size" => 100_000,
          "upload_token" => presign_data["upload_token"]
        }
      })

    {200, _, update_body} =
      request(port, "POST", "/api/profiles/streamer/media", headers, update_payload)

    assert {:ok, update_data} = JSON.decode(update_body)
    assert update_data["ok"] == true
    assert update_data["storage_used_bytes"] == 100_000
    assert update_data["storage_pending_bytes"] == 0
    refute Map.has_key?(update_data, "cleanup_urls")

    # 3. Replacing media keeps the old object charged until server cleanup.
    presign2_payload =
      JSON.encode(%{
        "handle" => "streamer",
        "filename" => "new_chime.wav",
        "content_type" => "audio/wav",
        "size" => 150_000
      })

    {200, _, presign2_body} =
      request(port, "POST", "/api/media/presign", headers, presign2_payload)

    assert {:ok, presign2_data} = JSON.decode(presign2_body)

    update2_payload =
      JSON.encode(%{
        "alert_sound" => %{
          "url" => presign2_data["public_url"],
          "source" => "r2",
          "key" => presign2_data["key"],
          "size" => 150_000,
          "upload_token" => presign2_data["upload_token"]
        }
      })

    {200, _, update2_body} =
      request(port, "POST", "/api/profiles/streamer/media", headers, update2_payload)

    assert {:ok, update2_data} = JSON.decode(update2_body)
    assert update2_data["ok"] == true
    assert update2_data["storage_used_bytes"] == 150_000
    assert update2_data["storage_pending_bytes"] == 100_000
    refute Map.has_key?(update2_data, "cleanup_urls")

    assert Enum.any?(
             Profiles.media_objects(),
             &(&1["key"] == presign_data["key"] and &1["state"] == "retired")
           )

    # 4. Reject tampered upload_token (422)
    tampered_payload =
      JSON.encode(%{
        "alert_sound" => %{
          "url" => presign2_data["public_url"],
          "source" => "r2",
          "key" => presign2_data["key"],
          "upload_token" => "tampered.token.signature"
        }
      })

    {422, _, tampered_body} =
      request(port, "POST", "/api/profiles/streamer/media", headers, tampered_payload)

    assert {:ok, tampered_data} = JSON.decode(tampered_body)
    assert tampered_data["ok"] == false
    assert tampered_data["error"] =~ "Token de subida multimedia inválido"

    # 5. Reject payload exceeding quota (422)
    oversized_payload =
      JSON.encode(%{
        "alert_sound" => %{
          "url" => "https://media.example.com/audio/huge.mp3",
          "source" => "r2",
          "key" => "audio/huge.mp3",
          "size" => 15_000_000
        }
      })

    {422, _, over_body} =
      request(port, "POST", "/api/profiles/streamer/media", headers, oversized_payload)

    assert {:ok, over_data} = JSON.decode(over_body)
    assert over_data["ok"] == false
    assert over_data["error"] =~ "Token de subida multimedia inválido"
  end

  test "DELETE /api/profiles/:handle retains reserved objects for server cleanup", %{port: port} do
    headers = [{"origin", "http://localhost:#{port}"}, {"content-type", "application/json"}]

    {:ok, upload} =
      ChatOverlay.Media.validate_upload_request(
        %{"filename" => "badge.png", "content_type" => "image/png", "size" => 50_000},
        0
      )

    {:ok, object} = Profiles.reserve_media_upload("streamer", upload)
    {200, _, body} = request(port, "DELETE", "/api/profiles/streamer", headers)
    assert {:ok, %{"ok" => true} = data} = JSON.decode(body)
    refute Map.has_key?(data, "cleanup_urls")

    assert Enum.any?(
             Profiles.media_objects(),
             &(&1["key"] == object["key"] and &1["state"] == "retired")
           )
  end

  test "SSE stream enforces capability token when view=overlay", %{port: port} do
    # Regenerate token for streamer
    assert {:ok, token, _} = Profiles.regenerate_capability_token("streamer")

    # Connect to SSE without token -> 401
    {401, _, body} = request(port, "GET", "/events/streamer?view=overlay")
    assert body =~ "Capability Token Invalid"

    # Connect to SSE with wrong token -> 401
    {401, _, body2} = request(port, "GET", "/events/streamer?view=overlay&token=wrong")
    assert body2 =~ "Capability Token Invalid"

    # Connect to SSE with valid token -> begins streaming (200)
    conn = connection(port)

    ref =
      ChatOverlay.TestClient.request(
        conn,
        "GET",
        "/events/streamer?view=overlay&token=" <> token,
        [],
        ""
      )

    assert {:response, :nofin, 200, _} = ChatOverlay.TestClient.await(conn, ref)
    assert {:data, :nofin, chunk} = ChatOverlay.TestClient.await(conn, ref)
    assert chunk =~ "retry: 2000"
    ChatOverlay.TestClient.close(conn)
  end

  defp await_error(conn, ref, buffer \\ "") do
    case String.split(buffer, "\n\n", parts: 2) do
      [frame, rest] ->
        if frame =~ "event: error" do
          frame <> "\n\n"
        else
          await_error(conn, ref, rest)
        end

      [_incomplete] ->
        case ChatOverlay.TestClient.await(conn, ref, 2000) do
          {:data, :nofin, data} ->
            await_error(conn, ref, buffer <> data)

          other ->
            other
        end
    end
  end

  test "active SSE overlay viewers are disconnected on token regeneration (SEC-09)", %{port: port} do
    assert {:ok, token, _} = Profiles.regenerate_capability_token("streamer")

    # Connect viewer 1
    conn1 = connection(port)

    ref1 =
      ChatOverlay.TestClient.request(
        conn1,
        "GET",
        "/events/streamer?view=overlay&token=" <> token,
        [],
        ""
      )

    assert {:response, :nofin, 200, _} = ChatOverlay.TestClient.await(conn1, ref1)
    assert {:data, :nofin, chunk1} = ChatOverlay.TestClient.await(conn1, ref1)
    assert chunk1 =~ "retry: 2000"

    # Connect viewer 2
    conn2 = connection(port)

    ref2 =
      ChatOverlay.TestClient.request(
        conn2,
        "GET",
        "/events/streamer?view=overlay&token=" <> token,
        [],
        ""
      )

    assert {:response, :nofin, 200, _} = ChatOverlay.TestClient.await(conn2, ref2)
    assert {:data, :nofin, chunk2} = ChatOverlay.TestClient.await(conn2, ref2)
    assert chunk2 =~ "retry: 2000"

    # Regenerate capability token -> should actively disconnect both viewers
    assert {:ok, new_token, _} = Profiles.regenerate_capability_token("streamer")
    assert new_token != token

    # Viewer 1 receives revocation error chunk and terminates
    err1 = await_error(conn1, ref1)
    assert is_binary(err1)
    assert err1 =~ "event: error"
    assert err1 =~ "Capability token revoked"
    fin1 = ChatOverlay.TestClient.await(conn1, ref1, 2000)
    assert fin1 in [{:done, ""}, {:error, :closed}]
    ChatOverlay.TestClient.close(conn1)

    # Viewer 2 receives revocation error chunk and terminates
    err2 = await_error(conn2, ref2)
    assert is_binary(err2)
    assert err2 =~ "event: error"
    assert err2 =~ "Capability token revoked"
    fin2 = ChatOverlay.TestClient.await(conn2, ref2, 2000)
    assert fin2 in [{:done, ""}, {:error, :closed}]
    ChatOverlay.TestClient.close(conn2)

    # Reconnecting with revoked token is rejected with 401
    {401, _, rejected_body} =
      request(port, "GET", "/events/streamer?view=overlay&token=" <> token)

    assert rejected_body =~ "Capability Token Invalid"

    # Connecting with new token succeeds
    conn3 = connection(port)

    ref3 =
      ChatOverlay.TestClient.request(
        conn3,
        "GET",
        "/events/streamer?view=overlay&token=" <> new_token,
        [],
        ""
      )

    assert {:response, :nofin, 200, _} = ChatOverlay.TestClient.await(conn3, ref3)
    assert {:data, :nofin, chunk3} = ChatOverlay.TestClient.await(conn3, ref3)
    assert chunk3 =~ "retry: 2000"
    ChatOverlay.TestClient.close(conn3)
  end

  test "active SSE overlay viewers are disconnected on profile deletion (SEC-09)", %{port: port} do
    assert {:ok, token, _} = Profiles.regenerate_capability_token("streamer")

    conn = connection(port)

    ref =
      ChatOverlay.TestClient.request(
        conn,
        "GET",
        "/events/streamer?view=overlay&token=" <> token,
        [],
        ""
      )

    assert {:response, :nofin, 200, _} = ChatOverlay.TestClient.await(conn, ref)
    assert {:data, :nofin, chunk} = ChatOverlay.TestClient.await(conn, ref)
    assert chunk =~ "retry: 2000"

    # Delete profile -> should actively disconnect viewer
    assert :ok = Profiles.delete("streamer")

    err = await_error(conn, ref)
    assert is_binary(err)
    assert err =~ "event: error"
    assert err =~ "Capability token revoked"
    fin = ChatOverlay.TestClient.await(conn, ref, 2000)
    assert fin in [{:done, ""}, {:error, :closed}]
    ChatOverlay.TestClient.close(conn)
  end

  test "HTTP/1.1 keep-alive unregisters viewer and isolates subsequent streams on reused connection",
       %{port: port} do
    assert {:ok, token1, _} = Profiles.regenerate_capability_token("streamer")
    assert {:ok, token2, _} = Profiles.regenerate_capability_token("streamer2")

    conn = connection(port)

    # 1. Connect to streamer on keep-alive connection
    ref1 =
      ChatOverlay.TestClient.request(
        conn,
        "GET",
        "/events/streamer?view=overlay&token=" <> token1,
        [],
        ""
      )

    assert {:response, :nofin, 200, _} = ChatOverlay.TestClient.await(conn, ref1)
    assert {:data, :nofin, chunk1} = ChatOverlay.TestClient.await(conn, ref1)
    assert chunk1 =~ "retry: 2000"

    # Verify registration exists in SSERegistry
    assert Registry.lookup(ChatOverlay.SSERegistry, "streamer") != []

    # 2. Regenerate capability token for streamer -> disconnects stream 1
    assert {:ok, _new_token1, _} = Profiles.regenerate_capability_token("streamer")

    err1 = await_error(conn, ref1)
    assert is_binary(err1)
    assert err1 =~ "Capability token revoked"
    fin1 = ChatOverlay.TestClient.await(conn, ref1, 2000)
    assert fin1 in [{:done, ""}, {:error, :closed}]

    # 3. CRITICAL: SSERegistry unregisters handle on response end even though Bandit
    # keeps the socket process alive for HTTP/1.1 keep-alive
    assert Registry.lookup(ChatOverlay.SSERegistry, "streamer") == []

    # 4. REUSE the same HTTP/1.1 keep-alive connection for streamer2
    ref2 =
      ChatOverlay.TestClient.request(
        conn,
        "GET",
        "/events/streamer2?view=overlay&token=" <> token2,
        [],
        ""
      )

    assert {:response, :nofin, 200, _} = ChatOverlay.TestClient.await(conn, ref2)
    assert {:data, :nofin, chunk2} = ChatOverlay.TestClient.await(conn, ref2)
    assert chunk2 =~ "retry: 2000"

    # Verify streamer2 is registered, and streamer is still empty
    assert Registry.lookup(ChatOverlay.SSERegistry, "streamer2") != []
    assert Registry.lookup(ChatOverlay.SSERegistry, "streamer") == []

    # 5. Regenerating streamer AGAIN must NOT disrupt streamer2 on this reused connection
    assert {:ok, _another_token1, _} = Profiles.regenerate_capability_token("streamer")

    # Ensure no spurious message disconnects streamer2
    Process.sleep(100)
    assert Registry.lookup(ChatOverlay.SSERegistry, "streamer2") != []

    # 6. Now regenerate streamer2 -> actively disconnects stream 2
    assert {:ok, _new_token2, _} = Profiles.regenerate_capability_token("streamer2")

    err2 = await_error(conn, ref2)
    assert is_binary(err2)
    assert err2 =~ "Capability token revoked"
    fin2 = ChatOverlay.TestClient.await(conn, ref2, 2000)
    assert fin2 in [{:done, ""}, {:error, :closed}]

    # Verify streamer2 registry entry is cleaned up on exit
    assert Registry.lookup(ChatOverlay.SSERegistry, "streamer2") == []

    # 7. Test that 401 exit also leaves no stale registration
    ref3 =
      ChatOverlay.TestClient.request(
        conn,
        "GET",
        "/events/streamer?view=overlay&token=invalid_token",
        [],
        ""
      )

    assert {:response, :nofin, 401, _} = ChatOverlay.TestClient.await(conn, ref3)
    assert Registry.lookup(ChatOverlay.SSERegistry, "streamer") == []

    ChatOverlay.TestClient.close(conn)
  end
end
