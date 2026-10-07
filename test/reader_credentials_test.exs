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
end
