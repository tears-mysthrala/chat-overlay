defmodule ChatOverlay.ReaderCredentialsTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Config, Net, Profiles, Source, Tokens}

  setup do
    original = Config.profiles()
    Tokens.clear()

    source = %{
      "platform" => "twitch",
      "channel" => "123",
      "user_id" => "123",
      "client_id" => "test-client",
      "credential_env" => "CHAT_TWITCH_TOKEN"
    }

    Application.put_env(:chat_overlay, :profiles, [
      %{"handle" => "readera", "sources" => [source]},
      %{"handle" => "readerb", "sources" => [source]}
    ])

    System.put_env("CHAT_TWITCH_TOKEN", "operator-token")

    on_exit(fn ->
      for h <- ["readera", "readerb"], do: Profiles.delete(h)
      Application.put_env(:chat_overlay, :profiles, original)
      Tokens.clear()
      System.delete_env("CHAT_TWITCH_TOKEN")
    end)

    %{source: source}
  end

  defp link(handle, token) do
    Profiles.link_account(handle, "twitch", %{user_id: "123", username: handle}, %{
      "access_token" => token,
      "refresh_token" => "synthetic-refresh",
      "expires_in" => 7200
    })
  end

  test "same channel remains isolated by owner; unlink stops its worker and never falls back to environment",
       %{source: operator} do
    assert {:ok, _} = link("readera", "token-a")
    assert {:ok, _} = link("readerb", "token-b")
    a = hd(Config.profile("readera")["sources"])
    b = hd(Config.profile("readerb")["sources"])
    refute Config.key(a) == Config.key(b)
    assert Config.handles(a) == ["readera"]
    assert {:ok, "token-a"} = Net.token(a)
    assert {:ok, "token-b"} = Net.token(b)
    assert {:ok, "operator-token"} = Net.token(operator)
    pid = GenServer.whereis(Source.name(a))
    assert is_pid(pid)
    monitor = Process.monitor(pid)
    assert {:ok, _} = Profiles.unlink_account("readera", "twitch")
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    assert {:error, :configuration_error} = Net.token(a)
    assert {:error, :configuration_error} = Net.token(hd(Config.profile("readera")["sources"]))
    assert {:ok, _} = Profiles.create_or_update(%{"handle" => "readera", "sources" => [operator]})
    assert {:error, :configuration_error} = Net.token(hd(Config.profile("readera")["sources"]))
    assert {:ok, "token-b"} = Net.token(b)
  end

  test "relink and reauth invalidate old reader contexts" do
    assert {:ok, _} = link("readera", "token-first")
    old = hd(Config.profile("readera")["sources"])
    assert {:ok, "token-first"} = Net.token(old)
    assert {:ok, _} = link("readera", "token-second")
    current = hd(Config.profile("readera")["sources"])
    assert {:error, :configuration_error} = Net.token(old)
    assert {:ok, "token-second"} = Net.token(current)
    assert {:ok, _} = Profiles.mark_account_reauth_required("readera", "twitch")
    assert {:error, :configuration_error} = Net.token(current)
  end

  test "foreign source metadata and non-owner configuration are denied" do
    assert {:ok, _} = link("readera", "token-a")
    source = hd(Config.profile("readera")["sources"])
    assert {:error, :configuration_error} = Net.token(Map.put(source, "channel", "999"))
    assert {:error, :configuration_error} = Net.token(Map.delete(source, "auth_version"))

    assert {:error, :invalid_configuration} =
             Config.validate([
               %{"handle" => "readerb", "sources" => [source]}
             ])
  end

  test "existing profiles opt into OAuth through serialized activation", %{source: source} do
    assert {:ok, _} = link("readera", "token-a")
    profile = Config.profile("readera") |> Map.put("sources", [source])
    Application.put_env(:chat_overlay, :profiles, [profile])
    assert {:ok, _} = Profiles.activate_oauth_readers("readera")
    assert {:ok, "token-a"} = Net.token(hd(Config.profile("readera")["sources"]))
  end

  test "revocation survives demo transitions and rejects target resolution", %{source: source} do
    assert {:ok, _} = link("readera", "token-a")
    assert {:ok, _} = Profiles.unlink_account("readera", "twitch")

    assert {:ok, _} =
             Profiles.create_or_update(%{
               "handle" => "readera",
               "sources" => [Map.put(source, "mode", "demo")]
             })

    assert {:ok, _} = Profiles.create_or_update(%{"handle" => "readera", "sources" => [source]})
    assert {:error, :configuration_error} = Net.token(hd(Config.profile("readera")["sources"]))

    assert {:error, :not_linked} =
             Profiles.create_or_update(%{"handle" => "readera", "target" => "readera"})

    assert {:error, :not_linked} =
             Profiles.create_or_update(%{
               "handle" => "readera",
               "sources" => [%{"platform" => "twitch", "target" => "readera"}]
             })
  end

  test "fresh cache from previous binding cannot supply a new reader" do
    assert {:ok, _} = link("readera", "token-old")
    assert {:ok, "token-old"} = Net.token(hd(Config.profile("readera")["sources"]))
    old_cache = :sys.get_state(Tokens).cache
    assert {:ok, _} = link("readera", "token-new")
    # Model the cache-publication interleaving before post-save invalidation.
    :sys.replace_state(Tokens, &%{&1 | cache: old_cache})
    assert {:ok, "token-new"} = Net.token(hd(Config.profile("readera")["sources"]))
  end

  test "queued failure from previous binding cannot invalidate relinked account" do
    assert {:ok, _} = link("readera", "token-old")
    old_version = Config.profile("readera")["linked_accounts"]["twitch"]["account_version"]
    assert {:ok, _} = link("readera", "token-new")

    assert {:error, :stale_binding} =
             Profiles.mark_account_reauth_required("readera", "twitch", :invalid_grant,
               expected_version: old_version,
               invalidate_cache: false
             )

    assert Config.profile("readera")["linked_accounts"]["twitch"]["status"] == "active"
    assert {:ok, "token-new"} = Net.token(hd(Config.profile("readera")["sources"]))
  end

  test "Twitch target cannot autodiscover with revoked YouTube operator credentials" do
    assert :ok = Profiles.delete("readerb")

    assert {:ok, _} =
             Profiles.link_account("readera", "youtube", %{user_id: "owned-youtube"}, %{
               "access_token" => "synthetic-google",
               "expires_in" => 7200
             })

    assert {:ok, _} = Profiles.unlink_account("readera", "youtube")
    owner = self()
    original = Application.get_env(:chat_overlay, :resolver_http_client)

    Application.put_env(:chat_overlay, :resolver_http_client, fn host, _, _, _, _ ->
      send(owner, {:resolver_host, host})

      body =
        case host do
          "id.twitch.tv" ->
            %{"client_id" => "test-client", "user_id" => "123", "login" => "readera"}

          "api.twitch.tv" ->
            %{
              "data" => [
                %{
                  "id" => "123",
                  "login" => "readera",
                  "display_name" => "Reader",
                  "description" => "https://www.youtube.com/@readera"
                }
              ]
            }

          _ ->
            flunk("Unexpected secondary resolver request to #{host}")
        end

      {:ok, 200, [], ChatOverlay.JSON.encode(body)}
    end)

    on_exit(fn ->
      if original,
        do: Application.put_env(:chat_overlay, :resolver_http_client, original),
        else: Application.delete_env(:chat_overlay, :resolver_http_client)
    end)

    assert {:ok, _} =
             Profiles.create_or_update(%{
               "handle" => "readera",
               "target" => "https://twitch.tv/readera"
             })

    assert_receive {:resolver_host, "id.twitch.tv"}
    assert_receive {:resolver_host, "api.twitch.tv"}
    refute_receive {:resolver_host, "www.googleapis.com"}
  end
end
