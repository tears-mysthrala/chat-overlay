defmodule ChatOverlay.Custodian.TLSTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.Custodian.{Client, Listener}

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "custodian-tls-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    openssl([
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-days",
      "1",
      "-config",
      "/dev/null",
      "-subj",
      "/CN=synthetic-custodian-ca",
      "-addext",
      "basicConstraints=critical,CA:TRUE",
      "-addext",
      "keyUsage=critical,keyCertSign,cRLSign",
      "-keyout",
      root <> "/ca.key",
      "-out",
      root <> "/ca.crt"
    ])

    for {name, usage, serial} <- [{"server", "serverAuth", "2"}, {"client", "clientAuth", "3"}] do
      openssl([
        "req",
        "-new",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-config",
        "/dev/null",
        "-subj",
        "/CN=" <> name,
        "-keyout",
        root <> "/" <> name <> ".key",
        "-out",
        root <> "/" <> name <> ".csr"
      ])

      File.write!(
        root <> "/" <> name <> ".ext",
        "basicConstraints=critical,CA:FALSE\n" <>
          "keyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=" <>
          usage <>
          "\nsubjectAltName=DNS:custodian.test\n"
      )

      openssl([
        "x509",
        "-req",
        "-in",
        root <> "/" <> name <> ".csr",
        "-CA",
        root <> "/ca.crt",
        "-CAkey",
        root <> "/ca.key",
        "-set_serial",
        serial,
        "-days",
        "1",
        "-extfile",
        root <> "/" <> name <> ".ext",
        "-out",
        root <> "/" <> name <> ".crt"
      ])
    end

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  setup %{root: root} do
    origin = Application.get_env(:chat_overlay, :oauth_origin)
    config = Application.get_env(:chat_overlay, :custodian_client)
    Application.put_env(:chat_overlay, :oauth_origin, "https://overlay.example.test")

    listener =
      start_supervised!(
        {Listener,
         [
           ip: {127, 0, 0, 1},
           port: 0,
           certfile: root <> "/server.crt",
           keyfile: root <> "/server.key",
           cacertfile: root <> "/ca.crt"
         ]}
      )

    port = Listener.port(listener)

    client = [
      address: {127, 0, 0, 1},
      hostname: "custodian.test",
      port: port,
      certfile: root <> "/client.crt",
      keyfile: root <> "/client.key",
      cacertfile: root <> "/ca.crt"
    ]

    Application.put_env(:chat_overlay, :custodian_client, client)

    on_exit(fn ->
      restore(:oauth_origin, origin)
      restore(:custodian_client, config)
    end)

    %{port: port, client: client}
  end

  test "real mutually authenticated connection executes the closed readiness operation" do
    assert {:ok, %{"version" => 1, "kind" => "readiness", "ready" => true}} =
             Client.call(request())
  end

  test "public frontend sends the user credential to the private handler over real TLS" do
    {:ok, token} = ChatOverlay.Session.create_token(%{"handle" => "test"})

    conn =
      Plug.Test.conn("GET", "/api/profiles")
      |> Plug.Conn.put_req_header("cookie", ChatOverlay.Session.cookie_name() <> "=" <> token)

    conn = %{conn | remote_ip: {198, 51, 100, 10}, scheme: :https, host: "overlay.example.test"}
    response = ChatOverlay.Custodian.Frontend.call(conn, [])
    assert response.status == 200
    assert {:ok, %{"profiles" => profiles}} = ChatOverlay.JSON.decode(response.resp_body)
    assert Enum.map(profiles, & &1["handle"]) == ["test"]
  end

  test "custodian failure does not fall back to local profile state", %{client: client} do
    Application.put_env(:chat_overlay, :custodian_client, Keyword.put(client, :port, 1))
    conn = %{Plug.Test.conn("GET", "/api/profiles") | remote_ip: {198, 51, 100, 10}}
    assert ChatOverlay.Custodian.Frontend.call(conn, []).status == 503
  end

  test "both OAuth starts and cancelled callbacks preserve their real binding cookies over mTLS" do
    {:ok, token} = ChatOverlay.Session.create_token(%{"handle" => "test"})

    for provider <- ["twitch", "youtube"] do
      conn =
        Plug.Test.conn("GET", "/api/oauth/authorize/" <> provider <> "?handle=test")
        |> Plug.Conn.put_req_header("cookie", ChatOverlay.Session.cookie_name() <> "=" <> token)

      conn = %{
        conn
        | remote_ip: {198, 51, 100, 10},
          scheme: :https,
          host: "overlay.example.test",
          port: 443
      }

      response = ChatOverlay.Custodian.Frontend.call(conn, [])
      assert response.status == 200
      assert {:ok, %{"ok" => true, "url" => url}} = ChatOverlay.JSON.decode(response.resp_body)
      state = URI.decode_query(URI.parse(url).query)["state"]
      name = ChatOverlay.OAuthFlow.cookie_name(state, true)
      binding = response.resp_cookies[name]
      assert binding.secure and binding.http_only
      assert binding.same_site == "Lax"

      callback =
        Plug.Test.conn(
          "GET",
          "/oauth/callback/" <>
            provider <>
            "?" <>
            URI.encode_query(%{"state" => state, "error" => "access_denied"})
        )
        |> Plug.Conn.put_req_header("cookie", name <> "=" <> binding.value)

      callback = %{
        callback
        | remote_ip: {198, 51, 100, 10},
          scheme: :https,
          host: "overlay.example.test",
          port: 443
      }

      cancelled = ChatOverlay.Custodian.Frontend.call(callback, [])
      assert cancelled.status == 302
      assert List.first(Plug.Conn.get_resp_header(cancelled, "location")) =~ "error=access_denied"
      assert cancelled.resp_cookies[name].max_age == 0
    end
  end

  test "maximum raw audio traverses the validated media route and mTLS wire ceiling" do
    previous =
      Map.new(
        [:media_storage, :media_objects, :local_media_http_client],
        &{&1, Application.fetch_env(:chat_overlay, &1)}
      )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:chat_overlay, key, value)
        {key, :error} -> Application.delete_env(:chat_overlay, key)
      end)
    end)

    # Synthetic trusted ready-object bytes exercise transport, not WAV decoding.
    bytes = :binary.copy(<<0>>, 2_097_152)
    hash = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    key = "test/validated/" <> String.duplicate("a", 32) <> "/" <> hash <> ".wav"
    Application.put_env(:chat_overlay, :media_storage, "local")

    Application.put_env(:chat_overlay, :media_objects, [
      %{
        "key" => key,
        "handle" => "test",
        "state" => "ready",
        "backend" => "local",
        "bucket" => "public",
        "mime" => "audio/wav",
        "size" => byte_size(bytes),
        "output_sha256" => hash
      }
    ])

    Application.put_env(:chat_overlay, :local_media_http_client, fn "GET",
                                                                    "public",
                                                                    ^key,
                                                                    "",
                                                                    nil ->
      {:ok, 200, [], bytes}
    end)

    conn = %{Plug.Test.conn("GET", "/media/local/" <> key) | remote_ip: {198, 51, 100, 10}}
    response = ChatOverlay.Custodian.Frontend.call(conn, [])

    assert response.status == 200
    assert response.resp_body == bytes
    assert Plug.Conn.get_resp_header(response, "content-type") == ["audio/wav"]
  end

  test "HTTP frontend relays a real private SSE snapshot and reader-session revocation" do
    original_proxies = Application.get_env(:chat_overlay, :trusted_proxy_ips, [])
    Application.put_env(:chat_overlay, :trusted_proxy_ips, [{127, 0, 0, 1}])
    on_exit(fn -> Application.put_env(:chat_overlay, :trusted_proxy_ips, original_proxies) end)

    front =
      start_supervised!(
        {Bandit,
         [
           plug: ChatOverlay.Custodian.Frontend,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           http_2_options: [enabled: false]
         ]}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(front)
    {:ok, token} = ChatOverlay.Session.create_token(%{"handle" => "test"})
    {:ok, client} = ChatOverlay.TestClient.open(~c"127.0.0.1", port, [])
    on_exit(fn -> ChatOverlay.TestClient.close(client) end)

    ref =
      ChatOverlay.TestClient.get(client, "/events/test", [
        {"cookie", ChatOverlay.Session.cookie_name() <> "=" <> token},
        {"x-forwarded-for", "198.51.100.10"}
      ])

    assert {:response, :nofin, 200, _} = ChatOverlay.TestClient.await(client, ref)
    assert stream_contains?(client, ref, "event: batch", 20)
    :ok = ChatOverlay.Session.revoke_token(token)
    assert stream_contains?(client, ref, "unauthorized", 20)
  end

  test "full SSE admission preserves operation capacity on the private listener" do
    {:ok, session} = ChatOverlay.Session.create_token(%{"handle" => "test"})
    initial_leases = :sys.get_state(ChatOverlay.Admission).viewers |> Map.keys()

    request = %{
      "version" => 1,
      "operation" => "events.subscribe",
      "arguments" => %{
        "handle" => "test",
        "view" => "reader",
        "session" => session
      }
    }

    clients =
      Enum.map(1..100, fn _ ->
        {:ok, conn} = Client.open()
        on_exit(fn -> Mint.HTTP.close(conn) end)

        {:ok, conn, ref} =
          Mint.HTTP.request(
            conn,
            "POST",
            "/v1/events",
            [{"content-type", "application/json"}],
            ChatOverlay.JSON.encode(request)
          )

        {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, 3000)
        assert Enum.any?(responses, &match?({:status, ^ref, 200}, &1))
        conn
      end)

    try do
      for _ <- 1..3 do
        assert {:ok, %{"kind" => "readiness", "ready" => true}} = Client.call(request())
      end
    after
      # Closing a socket is asynchronous; exercise the real revocation path and
      # wait for these leases to disappear before the next test acquires slots.
      :ok = ChatOverlay.Session.revoke_token(session)
      Enum.each(clients, &Mint.HTTP.close/1)
      assert admission_released?(initial_leases, 100)
    end
  end

  defp admission_released?(_initial_leases, 0), do: false

  defp admission_released?(initial_leases, attempts) do
    leases = :sys.get_state(ChatOverlay.Admission).viewers |> Map.keys()

    if Enum.all?(leases, &(&1 in initial_leases)) do
      true
    else
      Process.sleep(20)
      admission_released?(initial_leases, attempts - 1)
    end
  end

  test "binary upload traverses HTTP and mTLS only with a live reservation and session" do
    keys = [:media_storage, :profiles, :media_objects, :local_media_http_client]
    previous = Map.new(keys, &{&1, Application.fetch_env(:chat_overlay, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:chat_overlay, key, value)
        {key, :error} -> Application.delete_env(:chat_overlay, key)
      end)
    end)

    Application.put_env(:chat_overlay, :media_storage, "local")
    profile = ChatOverlay.Config.profile("test") |> Map.put("can_upload", true)
    Application.put_env(:chat_overlay, :profiles, [profile])
    key = "test/image/" <> String.duplicate("a", 32) <> "_fixture.png"

    object = %{
      "handle" => "test",
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
    {:ok, upload_token} = ChatOverlay.Media.generate_upload_token("test", key, 4, "image")
    {:ok, session} = ChatOverlay.Session.create_token(%{"handle" => "test"})
    parent = self()

    Application.put_env(:chat_overlay, :local_media_http_client, fn method,
                                                                    bucket,
                                                                    actual,
                                                                    body,
                                                                    mime ->
      send(parent, {:fixture_storage, method, bucket, actual, body, mime})
      {:ok, 201, [], ""}
    end)

    response = upload_fixture(session, upload_token, key)
    assert response.status == 201
    assert_receive {:fixture_storage, "PUT", "quarantine", ^key, "DATA", "image/png"}
    :ok = ChatOverlay.Session.revoke_token(session)
    assert upload_fixture(session, upload_token, key).status == 422
    refute_receive {:fixture_storage, _, _, _, _, _}
  end

  defp upload_fixture(session, token, key) do
    conn =
      Plug.Test.conn("PUT", "/api/media/upload/test", "DATA")
      |> Plug.Conn.put_req_header("cookie", ChatOverlay.Session.cookie_name() <> "=" <> session)
      |> Plug.Conn.put_req_header("origin", "https://overlay.example.test")
      |> Plug.Conn.put_req_header("content-type", "image/png")
      |> Plug.Conn.put_req_header("x-upload-key", key)
      |> Plug.Conn.put_req_header("x-upload-token", token)

    conn = %{conn | remote_ip: {198, 51, 100, 10}}
    ChatOverlay.Custodian.Frontend.call(conn, [])
  end

  test "wrong hostname fails certificate verification", %{client: client} do
    Application.put_env(
      :chat_overlay,
      :custodian_client,
      Keyword.put(client, :hostname, "wrong.test")
    )

    assert {:error, :custodian_unavailable} = Client.call(request())
  end

  test "server requires a client certificate", %{root: root, port: port} do
    assert {:error, _} =
             :ssl.connect(
               {127, 0, 0, 1},
               port,
               [
                 active: false,
                 verify: :verify_peer,
                 cacertfile: String.to_charlist(root <> "/ca.crt"),
                 server_name_indication: ~c"custodian.test",
                 versions: [:"tlsv1.2"]
               ],
               3000
             )
  end

  test "a server-only certificate does not confer client identity", %{client: client, root: root} do
    Application.put_env(
      :chat_overlay,
      :custodian_client,
      client
      |> Keyword.put(:certfile, root <> "/server.crt")
      |> Keyword.put(:keyfile, root <> "/server.key")
    )

    assert {:error, :custodian_unavailable} = Client.call(request())
  end

  test "caller cannot select an HTTP path or arbitrary operation" do
    assert {:error, :custodian_unavailable} =
             Client.call(Map.put(request(), "path", "/api/profiles"))
  end

  defp request, do: %{"version" => 1, "operation" => "health.ready", "arguments" => %{}}
  defp stream_contains?(_, _, _, 0), do: false

  defp stream_contains?(client, ref, text, attempts) do
    case ChatOverlay.TestClient.await(client, ref, 300) do
      {:data, :nofin, bytes} ->
        String.contains?(bytes, text) or stream_contains?(client, ref, text, attempts - 1)

      {:error, :timeout} ->
        stream_contains?(client, ref, text, attempts - 1)

      _ ->
        false
    end
  end

  defp restore(key, nil), do: Application.delete_env(:chat_overlay, key)
  defp restore(key, value), do: Application.put_env(:chat_overlay, key, value)

  defp openssl(args) do
    {_, code} = System.cmd("openssl", args, stderr_to_stdout: true)
    if code != 0, do: raise("Synthetic certificate setup failed")
  end
end
