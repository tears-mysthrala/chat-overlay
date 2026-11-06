defmodule ChatOverlay.LifecycleHTTP do
  @moduledoc false
  # Fake upstream. Every request is recorded and may be held by the test, so an interleaving
  # is chosen on purpose instead of hoping a timer lands inside it.
  def request(host, method, path, headers, body) do
    state = Application.fetch_env!(:chat_overlay, :lifecycle_http)
    token = bearer(headers)
    send(state.owner, {:upstream, self(), host, path, token})

    if state.hold.(host, path, token) do
      receive do
        :release -> :ok
      after
        10_000 -> exit(:not_released)
      end
    end

    state.reply.(host, method, path, token, body)
  end

  defp bearer(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if k == "authorization", do: v |> String.split(" ") |> List.last()
    end)
  end
end

defmodule ChatOverlay.ReaderLifecycleTest do
  @moduledoc "Fixture acceptance of the existing reader integration, through Source, Store, Tokens and Profiles (#47)."
  use ExUnit.Case, async: false
  alias ChatOverlay.{Admission, Config, JSON, Net, Profiles, Source, Store, Tokens}

  @chat "chat-a"

  setup do
    original = Config.profiles()
    System.put_env("YOUTUBE_CLIENT_ID", "synthetic-id")
    System.put_env("YOUTUBE_CLIENT_SECRET", "synthetic-secret")
    Tokens.clear()

    Application.put_env(:chat_overlay, :request_module, ChatOverlay.LifecycleHTTP)
    set_http(fn _, _, _ -> false end)

    on_exit(fn ->
      for handle <- ~w(lifea lifeb), do: Profiles.delete(handle)
      Application.delete_env(:chat_overlay, :request_module)
      Application.delete_env(:chat_overlay, :lifecycle_http)
      Application.put_env(:chat_overlay, :profiles, original)
      Tokens.clear()
      System.delete_env("YOUTUBE_CLIENT_ID")
      System.delete_env("YOUTUBE_CLIENT_SECRET")
    end)

    :ok
  end

  defp set_http(hold, reply \\ &poll_reply/5) do
    Application.put_env(:chat_overlay, :lifecycle_http, %{owner: self(), hold: hold, reply: reply})
  end

  defp poll_reply(_host, _method, path, token, _body) do
    chat = URI.decode_query(URI.parse(path).query)["liveChatId"]

    item = %{
      "id" => "msg-#{token}-#{System.unique_integer([:positive])}",
      "snippet" => %{
        "type" => "textMessageEvent",
        "liveChatId" => chat,
        "publishedAt" => DateTime.to_iso8601(DateTime.utc_now()),
        "displayMessage" => "from #{token}"
      },
      "authorDetails" => %{"channelId" => "author", "displayName" => "Autor"}
    }

    {:ok, 200, [],
     JSON.encode(%{
       "items" => [item],
       "pollingIntervalMillis" => 1000,
       "nextPageToken" => "next"
     })}
  end

  defp profile(handle, access, refresh \\ "refresh-1", expires_in \\ 7200, chat \\ @chat) do
    source = %{
      "platform" => "youtube",
      "channel" => "channel-#{handle}",
      "live_chat_id" => chat,
      "credential_env" => "CHAT_YOUTUBE_TOKEN"
    }

    {:ok, _} = Profiles.create_or_update(%{"handle" => handle, "sources" => [source]})

    {:ok, _} =
      Profiles.link_account(handle, "youtube", %{user_id: "owner-#{handle}", username: handle}, %{
        "access_token" => access,
        "refresh_token" => refresh,
        "expires_in" => expires_in
      })

    reader(handle)
  end

  defp reader(handle), do: hd(Config.profile(handle)["sources"])
  defp account(handle), do: Config.profile(handle)["linked_accounts"]["youtube"]

  defp watch(handle) do
    owner = self()

    spawn_link(fn ->
      :ok = Admission.acquire(handle)
      send(owner, {:watching, handle})
      Process.sleep(:infinity)
    end)

    assert_receive {:watching, ^handle}, 2000
  end

  defp next_poll(token, timeout \\ 5000) do
    assert_receive {:upstream, pid, "www.googleapis.com", _, ^token}, timeout
    pid
  end

  defp snapshot(handle) do
    Enum.find(Store.read(Store.name(handle)).events, &(&1["event"] == "snapshot"))["payload"]
  end

  defp state(handle) do
    case snapshot(handle)["source_states"] do
      [current | _] -> current["payload"]["state"]
      _ -> nil
    end
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  # Time passes without waiting for it: both the stored and the cached copy are now expired.
  defp expire(handle) do
    {:ok, _} =
      Profiles.update_tokens(handle, "youtube", %{
        "access_token" => "expired-#{handle}",
        "expires_in" => 1
      })

    :sys.replace_state(Tokens, fn s -> %{s | cache: Map.delete(s.cache, {handle, "youtube"})} end)
  end

  defp refresh_with(handle, reply) do
    Task.async(fn ->
      Tokens.get_access_token(handle, "youtube",
        http_client: fn :post, _, _, params ->
          reply.(params.refresh_token)
        end
      )
    end)
    |> Task.await(5000)
  end

  defp texts(handle), do: Enum.map(snapshot(handle)["messages"], & &1["payload"]["text"])

  test "expiry during a read moves the same worker to the new token with no gap" do
    profile("lifea", "token-1")
    set_http(fn _, _, token -> token == "token-1" end)
    watch("lifea")
    worker = next_poll("token-1")

    expire("lifea")

    assert {:ok, "token-2"} =
             refresh_with("lifea", fn "refresh-1" ->
               {:ok, 200, %{"access_token" => "token-2", "expires_in" => 3600}}
             end)

    send(worker, :release)
    assert next_poll("token-2") == worker

    assert eventually(fn -> "from token-2" in texts("lifea") end)

    assert "from token-1" in texts("lifea"), "a refresh must not clear what was already read"
    assert state("lifea") == "available"
  end

  test "ten concurrent readers per profile share one refresh and never each other's token" do
    profile("lifea", "old-a", "refresh-a", 1)
    profile("lifeb", "old-b", "refresh-b", 1)
    calls = :counters.new(1, [:atomics])
    owner = self()

    client = fn :post, _, _, params ->
      :counters.add(calls, 1, 1)
      send(owner, {:refreshing, self(), params.refresh_token})

      receive do
        :go ->
          {:ok, 200, %{"access_token" => "new-" <> params.refresh_token, "expires_in" => 3600}}
      after
        5000 -> {:error, :fixture_timeout}
      end
    end

    tasks =
      for handle <- ~w(lifea lifeb), _ <- 1..10 do
        {handle,
         Task.async(fn -> Tokens.get_access_token(handle, "youtube", http_client: client) end)}
      end

    assert_receive {:refreshing, first, _}, 2000
    assert_receive {:refreshing, second, _}, 2000
    # Let every caller queue behind the refresh before it finishes.
    Process.sleep(100)
    send(first, :go)
    send(second, :go)

    for {handle, task} <- tasks do
      expected = "new-refresh-" <> String.last(handle)
      assert {:ok, ^expected} = Task.await(task, 5000)
    end

    assert :counters.get(calls, 1) == 2
    assert {:ok, "new-refresh-a"} = Net.token(reader("lifea"))
    assert {:ok, "new-refresh-b"} = Net.token(reader("lifeb"))
  end

  test "rotation keeps the binding and worker, and the old refresh token is never reused" do
    profile("lifea", "token-1")
    set_http(fn _, _, token -> token == "token-1" end)
    watch("lifea")
    worker = next_poll("token-1")
    source_pid = GenServer.whereis(Source.name(reader("lifea")))
    version = account("lifea")["account_version"]

    expire("lifea")

    assert {:ok, "token-2"} =
             refresh_with("lifea", fn "refresh-1" ->
               {:ok, 200,
                %{
                  "access_token" => "token-2",
                  "refresh_token" => "refresh-2",
                  "expires_in" => 3600
                }}
             end)

    expire("lifea")

    assert {:ok, "token-3"} =
             refresh_with("lifea", fn "refresh-2" ->
               {:ok, 200, %{"access_token" => "token-3", "expires_in" => 3600}}
             end)

    assert account("lifea")["account_version"] == version
    assert GenServer.whereis(Source.name(reader("lifea"))) == source_pid
    send(worker, :release)
    assert next_poll("token-3") == worker
    refute inspect(Config.profile("lifea")) =~ "refresh-2"
  end

  test "invalid_grant during a read stops only that reader, reports it, and relink recovers" do
    profile("lifea", "token-a", "refresh-a")
    profile("lifeb", "token-b", "refresh-b", 7200, "chat-b")
    set_http(fn _, _, token -> token == "token-a" end)
    watch("lifea")
    watch("lifeb")
    worker = next_poll("token-a")
    other = next_poll("token-b")
    monitor = Process.monitor(worker)
    old = reader("lifea")

    expire("lifea")

    assert {:error, :reauth_required} =
             refresh_with("lifea", fn "refresh-a" ->
               {:ok, 400, %{"error" => "invalid_grant"}}
             end)

    assert account("lifea")["status"] == "reauth_required"
    assert account("lifea")["last_error"] == "invalid_grant"
    public = Profiles.public_summary(Config.profile("lifea"))
    assert public["linked_accounts"]["youtube"]["status"] == "reauth_required"
    refute inspect(public) =~ "refresh-a"
    refute inspect(public) =~ "token-a"
    assert {:error, :configuration_error} = Net.token(reader("lifea"))
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5000
    refute_receive {:upstream, _, _, _, "expired-lifea"}, 1500

    assert eventually(fn -> state("lifea") == "configuration_error" end)
    refute inspect(snapshot("lifea")) =~ "token-a"
    assert account("lifeb")["status"] == "active"
    assert Process.alive?(other)
    assert next_poll("token-b") == other

    {:ok, _} =
      Profiles.link_account("lifea", "youtube", %{user_id: "owner-lifea", username: "lifea"}, %{
        "access_token" => "token-new",
        "refresh_token" => "refresh-new",
        "expires_in" => 7200
      })

    refute reader("lifea") == old
    assert {:error, :configuration_error} = Net.token(old)
    assert next_poll("token-new", 8000)
    assert eventually(fn -> state("lifea") == "available" end)
  end

  test "upstream refusing a token still fresh locally reports it and keeps the account active" do
    # Observed behaviour, not a requirement to change: the reader retries the same token
    # until it nears expiry, when a refresh settles it either way.
    profile("lifea", "token-1")

    set_http(fn _, _, _ -> false end, fn host, method, path, token, body ->
      if token == "token-1",
        do: {:ok, 401, [], "{}"},
        else: poll_reply(host, method, path, token, body)
    end)

    watch("lifea")
    next_poll("token-1")
    assert eventually(fn -> state("lifea") == "configuration_error" end)
    assert account("lifea")["status"] == "active"
    assert {:ok, "token-1"} = Net.token(reader("lifea"))
  end

  # The worker queues behind a refresh the test controls, so nothing reaches the real network.
  defp failing_refresh(handle, error, provider \\ "youtube") do
    owner = self()

    client = fn :post, _, _, _ ->
      send(owner, {:refreshing, self()})

      receive do
        :go -> error
      after
        5000 -> {:error, :fixture_timeout}
      end
    end

    task = Task.async(fn -> Tokens.get_access_token(handle, provider, http_client: client) end)
    assert_receive {:refreshing, refresher}, 2000
    {task, refresher}
  end

  defp queued?(handle) do
    length(Map.get(:sys.get_state(Tokens).in_flight, {handle, "youtube"}, [])) >= 2
  end

  for {name, error} <- [
        {"network failure", {:error, :upstream_unavailable}},
        {"timeout", {:error, :upstream_timeout}},
        {"provider 5xx", {:ok, 503, %{}}}
      ] do
    test "transient refresh #{name} is degraded, keeps the account, and recovers" do
      profile("lifea", "token-1", "refresh-1", 1)
      {task, refresher} = failing_refresh("lifea", unquote(Macro.escape(error)))
      watch("lifea")
      assert eventually(&__MODULE__.lifea_queued?/0)
      send(refresher, :go)
      assert {:error, _} = Task.await(task, 5000)

      assert eventually(fn -> state("lifea") == "degraded" end)
      assert account("lifea")["status"] == "active"
      refute inspect(snapshot("lifea")) =~ "refresh-1"

      # The next refresh works before the worker's retry, which then reads with the new token.
      assert {:ok, "token-2"} =
               refresh_with("lifea", fn "refresh-1" ->
                 {:ok, 200, %{"access_token" => "token-2", "expires_in" => 3600}}
               end)

      assert next_poll("token-2", 8000)
      assert eventually(fn -> state("lifea") == "available" end)
    end
  end

  def lifea_queued?, do: queued?("lifea")

  for {name, error} <- [
        {"unclassified failure", {:error, :something_unexpected}},
        {"provider 403", {:ok, 403, %{}}},
        {"provider 429", {:ok, 429, %{}}},
        {"provider redirect", {:ok, 302, %{}}},
        {"malformed success", {:ok, 200, %{"access_token" => ""}}}
      ] do
    test "token #{name} fails closed as a configuration error" do
      profile("lifea", "token-1", "refresh-1", 1)
      {task, refresher} = failing_refresh("lifea", unquote(Macro.escape(error)))
      watch("lifea")
      assert eventually(&__MODULE__.lifea_queued?/0)
      send(refresher, :go)
      assert {:error, _} = Task.await(task, 5000)
      assert eventually(fn -> state("lifea") == "configuration_error" end)
      assert account("lifea")["status"] == "active"
    end
  end

  test "unlink during a read kills the worker and stops the old token; relink starts clean" do
    profile("lifea", "token-1")
    profile("lifeb", "token-b", "refresh-b", 7200, "chat-b")
    set_http(fn _, _, token -> token == "token-1" end)
    watch("lifea")
    watch("lifeb")
    worker = next_poll("token-1")
    other = next_poll("token-b")
    monitor = Process.monitor(worker)
    old = reader("lifea")
    source_pid = GenServer.whereis(Source.name(old))

    {:ok, _} = Profiles.unlink_account("lifea", "youtube")

    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5000
    refute Process.alive?(source_pid)
    send(worker, :release)
    refute_receive {:upstream, _, _, _, "token-1"}, 1500
    assert {:error, :configuration_error} = Net.token(old)
    assert next_poll("token-b") == other

    {:ok, _} =
      Profiles.link_account("lifea", "youtube", %{user_id: "owner-lifea", username: "lifea"}, %{
        "access_token" => "token-2",
        "refresh_token" => "refresh-2",
        "expires_in" => 7200
      })

    assert next_poll("token-2", 8000)
    refute_receive {:upstream, _, _, _, "token-1"}, 500
  end

  test "losing the last viewer stops a worker blocked in a request, and a refresh still completes" do
    Application.put_env(:chat_overlay, :grace_ms, 50)
    on_exit(fn -> Application.put_env(:chat_overlay, :grace_ms, 60_000) end)
    profile("lifea", "token-1")
    set_http(fn _, _, token -> token == "token-1" end)
    owner = self()

    viewer =
      spawn(fn ->
        :ok = Admission.acquire("lifea")
        send(owner, :watching)
        Process.sleep(:infinity)
      end)

    assert_receive :watching, 2000
    worker = next_poll("token-1")
    monitor = Process.monitor(worker)
    Process.exit(viewer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5000
    assert eventually(fn -> state("lifea") == "offline" end)

    expire("lifea")

    assert {:ok, "token-2"} =
             refresh_with("lifea", fn "refresh-1" ->
               {:ok, 200, %{"access_token" => "token-2", "expires_in" => 3600}}
             end)

    assert {:ok, "token-2"} = Net.token(reader("lifea"))
  end

  test "a reader killed while waiting on a refresh does not cancel it for the next caller" do
    profile("lifea", "token-1", "refresh-1", 1)
    owner = self()

    client = fn :post, _, _, _ ->
      send(owner, {:refreshing, self()})

      receive do
        :go -> {:ok, 200, %{"access_token" => "token-2", "expires_in" => 3600}}
      after
        5000 -> {:error, :fixture_timeout}
      end
    end

    victim =
      spawn(fn -> Tokens.get_access_token("lifea", "youtube", http_client: client) end)

    assert_receive {:refreshing, refresher}, 2000
    Process.exit(victim, :kill)
    next = Task.async(fn -> Tokens.get_access_token("lifea", "youtube", http_client: client) end)
    Process.sleep(50)
    send(refresher, :go)
    assert {:ok, "token-2"} = Task.await(next, 5000)
  end

  describe "Twitch socket read" do
    setup do
      {module, binary, file} = :code.get_object_code(ChatOverlay.Socket)
      options = Code.compiler_options()
      Code.compiler_options(ignore_module_conflict: true)
      Application.put_env(:chat_overlay, :lifecycle_socket_owner, self())

      # Test-only stand-in: the real module can only dial the fixed Twitch host.
      Code.compile_string("""
      defmodule ChatOverlay.Socket do
        defp owner, do: Application.fetch_env!(:chat_overlay, :lifecycle_socket_owner)

        def open(path) do
          send(owner(), {:socket_open, self(), path})
          {:ok, %{worker: self()}}
        end

        def recv(socket, timeout) do
          receive do
            {:frame, frame} -> {:ok, frame, socket}
          after
            min(timeout, 8000) -> {:error, :timeout}
          end
        end

        def pong(socket, _), do: {:ok, socket}

        def close(socket) do
          send(owner(), {:socket_closed, socket.worker})
          :ok
        end
      end
      """)

      on_exit(fn ->
        :code.purge(module)
        {:module, ^module} = :code.load_binary(module, file, binary)
        Code.compiler_options(ignore_module_conflict: options[:ignore_module_conflict])
        Application.delete_env(:chat_overlay, :lifecycle_socket_owner)
      end)

      set_http(fn _, _, _ -> false end, &twitch_reply/5)
      System.put_env("TWITCH_CLIENT_ID", "synthetic-id")
      System.put_env("TWITCH_CLIENT_SECRET", "synthetic-secret")

      on_exit(fn ->
        System.delete_env("TWITCH_CLIENT_ID")
        System.delete_env("TWITCH_CLIENT_SECRET")
      end)

      :ok
    end

    defp twitch_reply("id.twitch.tv", _, _, _, _) do
      {:ok, 200, [],
       JSON.encode(%{
         "client_id" => "synthetic-client",
         "user_id" => "123",
         "scopes" => ["user:read:chat"]
       })}
    end

    defp twitch_reply("api.twitch.tv", _, _, _, _), do: {:ok, 202, [], "{}"}

    defp twitch_profile(handle, channel, access, refresh, expires_in \\ 7200) do
      source = %{
        "platform" => "twitch",
        "channel" => channel,
        "user_id" => "123",
        "client_id" => "synthetic-client",
        "credential_env" => "CHAT_TWITCH_TOKEN"
      }

      {:ok, _} = Profiles.create_or_update(%{"handle" => handle, "sources" => [source]})

      {:ok, _} =
        Profiles.link_account(handle, "twitch", %{user_id: "123", username: handle}, %{
          "access_token" => access,
          "refresh_token" => refresh,
          "expires_in" => expires_in
        })

      reader(handle)
    end

    defp frame(worker, data), do: send(worker, {:frame, {:text, JSON.encode(data)}})

    defp connect(token) do
      assert_receive {:upstream, _, "id.twitch.tv", _, ^token}, 12_000
      assert_receive {:socket_open, worker, _}, 2000

      frame(worker, %{
        "metadata" => %{"message_type" => "session_welcome"},
        "payload" => %{"session" => %{"id" => "session", "keepalive_timeout_seconds" => 30}}
      })

      assert_receive {:upstream, ^worker, "api.twitch.tv", _, ^token}, 2000
      worker
    end

    defp chat(worker, channel, id, text) do
      frame(worker, %{
        "metadata" => %{
          "message_type" => "notification",
          "subscription_type" => "channel.chat.message",
          "message_id" => "meta-#{id}",
          "message_timestamp" => DateTime.to_iso8601(DateTime.utc_now())
        },
        "payload" => %{
          "event" => %{
            "broadcaster_user_id" => channel,
            "message_id" => id,
            "chatter_user_id" => "9",
            "chatter_user_name" => "Autor",
            "message" => %{"text" => text}
          }
        }
      })
    end

    defp flush_upstream do
      receive do
        {:upstream, _, _, _, _} -> flush_upstream()
      after
        0 -> :ok
      end
    end

    defp keepalive(worker) do
      frame(worker, %{"metadata" => %{"message_type" => "session_keepalive"}, "payload" => %{}})
    end

    defp expire_twitch(handle) do
      {:ok, _} =
        Profiles.update_tokens(handle, "twitch", %{"access_token" => "expired", "expires_in" => 1})

      :sys.replace_state(Tokens, fn s -> %{s | cache: Map.delete(s.cache, {handle, "twitch"})} end)
    end

    defp twitch_refresh(handle, reply) do
      Tokens.get_access_token(handle, "twitch",
        http_client: fn :post, _, _, params -> reply.(params.refresh_token) end
      )
    end

    test "a refreshed token reconnects with the new token and closes the old socket" do
      twitch_profile("lifea", "123", "token-1", "refresh-1")
      watch("lifea")
      worker = connect("token-1")
      chat(worker, "123", "m1", "before refresh")
      assert eventually(fn -> "before refresh" in texts("lifea") end)
      assert state("lifea") == "available"

      expire_twitch("lifea")

      assert {:ok, "token-2"} =
               twitch_refresh("lifea", fn "refresh-1" ->
                 {:ok, 200, %{"access_token" => "token-2", "expires_in" => 3600}}
               end)

      flush_upstream()
      keepalive(worker)
      assert_receive {:socket_closed, ^worker}, 2000
      assert eventually(fn -> state("lifea") == "degraded" end)
      next = connect("token-2")
      refute next == worker
      chat(next, "123", "m2", "after refresh")
      assert eventually(fn -> "after refresh" in texts("lifea") end)
      assert state("lifea") == "available"
      refute_received {:upstream, _, _, _, "token-1"}
    end

    test "a transient refresh failure at connect is degraded and recovers with the new token" do
      twitch_profile("lifea", "123", "token-1", "refresh-1", 1)
      {task, refresher} = failing_refresh("lifea", {:ok, 503, %{}}, "twitch")
      watch("lifea")

      assert eventually(fn ->
               length(Map.get(:sys.get_state(Tokens).in_flight, {"lifea", "twitch"}, [])) >= 2
             end)

      send(refresher, :go)
      assert {:error, :upstream_unavailable} = Task.await(task, 5000)
      assert eventually(fn -> state("lifea") == "degraded" end)
      refute_received {:socket_open, _, _}
      assert Config.profile("lifea")["linked_accounts"]["twitch"]["status"] == "active"

      assert {:ok, "token-2"} =
               twitch_refresh("lifea", fn "refresh-1" ->
                 {:ok, 200, %{"access_token" => "token-2", "expires_in" => 3600}}
               end)

      assert connect("token-2")
    end

    test "a transient refresh failure during a read closes the socket as degraded and recovers" do
      twitch_profile("lifea", "123", "token-1", "refresh-1")
      watch("lifea")
      worker = connect("token-1")
      expire_twitch("lifea")
      {task, refresher} = failing_refresh("lifea", {:error, :upstream_timeout}, "twitch")
      keepalive(worker)

      assert eventually(fn ->
               length(Map.get(:sys.get_state(Tokens).in_flight, {"lifea", "twitch"}, [])) >= 2
             end)

      send(refresher, :go)
      assert {:error, :upstream_timeout} = Task.await(task, 5000)
      assert_receive {:socket_closed, ^worker}, 2000
      assert eventually(fn -> state("lifea") == "degraded" end)

      assert {:ok, "token-2"} =
               twitch_refresh("lifea", fn "refresh-1" ->
                 {:ok, 200, %{"access_token" => "token-2", "expires_in" => 3600}}
               end)

      assert connect("token-2")
    end

    test "invalid_grant during a read stops that socket and leaves another profile reading" do
      twitch_profile("lifea", "123", "token-a", "refresh-a")
      watch("lifea")
      worker = connect("token-a")
      twitch_profile("lifeb", "456", "token-b", "refresh-b")
      watch("lifeb")
      other = connect("token-b")
      monitor = Process.monitor(worker)

      expire_twitch("lifea")

      assert {:error, :reauth_required} =
               twitch_refresh("lifea", fn "refresh-a" ->
                 {:ok, 400, %{"error" => "invalid_grant"}}
               end)

      flush_upstream()
      keepalive(worker)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5000
      refute_receive {:upstream, _, _, _, "token-a"}, 1500
      assert Config.profile("lifea")["linked_accounts"]["twitch"]["status"] == "reauth_required"
      assert eventually(fn -> state("lifea") in ["configuration_error", "degraded"] end)
      refute inspect(snapshot("lifea")) =~ "token-a"

      assert Config.profile("lifeb")["linked_accounts"]["twitch"]["status"] == "active"
      chat(other, "456", "b1", "other still reads")
      assert eventually(fn -> "other still reads" in texts("lifeb") end)
      refute "other still reads" in texts("lifea")
    end

    test "unlink during a read ends the worker and does not reconnect" do
      twitch_profile("lifea", "123", "token-1", "refresh-1")
      watch("lifea")
      worker = connect("token-1")
      monitor = Process.monitor(worker)
      {:ok, _} = Profiles.unlink_account("lifea", "twitch")
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5000
      refute_receive {:socket_open, _, _}, 1500
    end

    test "provider revocation stops as a configuration error without reconnecting at once" do
      twitch_profile("lifea", "123", "token-1", "refresh-1")
      watch("lifea")
      worker = connect("token-1")
      frame(worker, %{"metadata" => %{"message_type" => "revocation"}, "payload" => %{}})
      assert eventually(fn -> state("lifea") == "configuration_error" end)
      refute_receive {:socket_open, _, _}, 1500
    end
  end
end
