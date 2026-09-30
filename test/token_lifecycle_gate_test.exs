defmodule ChatOverlay.TokenLifecycleGateTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Profiles, Tokens}

  setup do
    original = Application.get_env(:chat_overlay, :profiles)
    original_path = Application.get_env(:chat_overlay, :profiles_path)
    path = Path.join(System.tmp_dir!(), "overlay-gate-#{System.unique_integer([:positive])}.json")
    Application.put_env(:chat_overlay, :profiles_path, path)

    Application.put_env(:chat_overlay, :profiles, [
      %{
        "handle" => "lifecycle",
        "sources" => [%{"platform" => "twitch", "channel" => "synthetic", "mode" => "demo"}]
      }
    ])

    Tokens.clear()

    on_exit(fn ->
      Tokens.clear()
      Application.put_env(:chat_overlay, :profiles, original)

      if original_path,
        do: Application.put_env(:chat_overlay, :profiles_path, original_path),
        else: Application.delete_env(:chat_overlay, :profiles_path)

      File.rm(path)
    end)

    {:ok, _} =
      Profiles.link_account(
        "lifecycle",
        "twitch",
        %{user_id: "synthetic", username: "Synthetic"},
        %{
          "access_token" => "synthetic-access",
          "refresh_token" => "synthetic-refresh",
          "expires_in" => 1
        }
      )

    :ok
  end

  # A refresh blocked at the transport boundary must be cancelled, not merely uncached.
  test "invalidation cancels pending refresh and replies to its caller" do
    {caller, worker, monitor} = blocked_refresh(Tokens)
    :ok = Tokens.invalidate("lifecycle", "twitch")
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 500
    assert {:error, _} = Task.await(caller, 1000)
  end

  # Abrupt coordinator death bypasses terminate/2: ownership must still hold.
  test "worker cannot outlive an abruptly terminated coordinator" do
    coordinator = start_supervised!({Tokens, name: :lifecycle_gate_tokens})
    {_caller, worker, monitor} = blocked_refresh(:lifecycle_gate_tokens)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 500
  end

  # Unlink/relink must not reuse a generation while an earlier result is pending.
  test "unlink and relink reject updates from the previous binding" do
    {:ok, auth} = Profiles.get_linked_account_auth("lifecycle", "twitch")
    previous_version = auth.account_version
    {:ok, _} = Profiles.unlink_account("lifecycle", "twitch")

    {:ok, _} =
      Profiles.link_account(
        "lifecycle",
        "twitch",
        %{user_id: "replacement", username: "Replacement"},
        %{
          "access_token" => "replacement-access",
          "refresh_token" => "replacement-refresh",
          "expires_in" => 7200
        }
      )

    result =
      Profiles.update_tokens(
        "lifecycle",
        "twitch",
        %{"access_token" => "obsolete-result", "expires_in" => 3600},
        expected_version: previous_version
      )

    assert {:error, :stale_binding} = result
    {:ok, tokens} = Profiles.get_linked_account_tokens("lifecycle", "twitch")
    assert tokens["access_token"] == "replacement-access"
  end

  defp blocked_refresh(server) do
    owner = self()

    client = fn _, _, _, _ ->
      send(owner, {:transport_entered, self()})

      receive do
        :release -> {:ok, 200, %{"access_token" => "synthetic-result", "expires_in" => 3600}}
      after
        2000 -> {:error, :synthetic_timeout}
      end
    end

    caller =
      Task.async(fn ->
        try do
          Tokens.get_access_token("lifecycle", "twitch", server: server, http_client: client)
        catch
          :exit, _ -> {:error, :coordinator_down}
        end
      end)

    # Keep a crashed coordinator from terminating the test through the caller link.
    Process.unlink(caller.pid)
    on_exit(fn -> if Process.alive?(caller.pid), do: Process.exit(caller.pid, :kill) end)
    assert_receive {:transport_entered, worker}, 1000
    monitor = Process.monitor(worker)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    {caller, worker, monitor}
  end
end
