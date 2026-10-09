defmodule ChatOverlay.Custodian.OperationsTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.Custodian.Operations
  alias ChatOverlay.Session

  setup do
    profiles = Application.get_env(:chat_overlay, :profiles)
    origin = Application.get_env(:chat_overlay, :oauth_origin)
    Application.put_env(:chat_overlay, :oauth_origin, "https://overlay.example.test")

    Application.put_env(
      :chat_overlay,
      :profiles,
      Enum.map(["alice", "bob"], fn handle ->
        %{
          "handle" => handle,
          "sources" => [],
          "linked_accounts" => %{
            "twitch" => %{"user_id" => handle <> "-id", "account_version" => 1}
          }
        }
      end)
    )

    on_exit(fn ->
      Application.put_env(:chat_overlay, :profiles, profiles)

      if origin,
        do: Application.put_env(:chat_overlay, :oauth_origin, origin),
        else: Application.delete_env(:chat_overlay, :oauth_origin)
    end)

    {:ok, token} =
      Session.create_token(%{
        "handle" => "alice",
        "provider" => "twitch",
        "user_id" => "alice-id",
        "account_version" => 1
      })

    %{token: token}
  end

  defp execute(op, args),
    do: Operations.execute(%{"version" => 1, "operation" => op, "arguments" => args})

  test "session identity is checked by the real handler and output contains public metadata", %{
    token: token
  } do
    assert {:ok, %{"kind" => "json", "data" => data}} =
             execute("session.get", %{"session" => token})

    assert data["authenticated"] == true
    assert data["handle"] == "alice"
    refute Map.has_key?(data, "access_token")
    refute Map.has_key?(data, "session")
  end

  test "a valid session cannot mutate another profile", %{token: token} do
    assert {:ok, %{"status" => 403}} =
             execute("profiles.delete", %{
               "session" => token,
               "handle" => "bob",
               "origin" => "https://overlay.example.test"
             })

    assert ChatOverlay.Config.profile("bob") != nil
  end

  test "custodian deletion rejects an old authenticated session without mutating the profile" do
    {:ok, old} =
      Session.create_token(
        %{
          "handle" => "alice",
          "provider" => "twitch",
          "user_id" => "alice-id",
          "account_version" => 1
        },
        now: System.system_time(:second) - 301
      )

    before = ChatOverlay.Config.profile("alice")

    assert {:ok, %{"status" => 403}} =
             execute("profiles.delete", %{
               "session" => old,
               "handle" => "alice",
               "origin" => "https://overlay.example.test"
             })

    assert ChatOverlay.Config.profile("alice") == before
  end

  test "logout revokes the actual token and subsequent calls lose authentication", %{token: token} do
    assert {:ok, %{"status" => 200}} =
             execute("session.logout", %{
               "session" => token,
               "origin" => "https://overlay.example.test"
             })

    assert {:error, :revoked} = Session.verify_token(token)

    assert {:ok, %{"data" => %{"authenticated" => false}}} =
             execute("session.get", %{"session" => token})
  end

  test "the internal channel cannot claim a local demo exception" do
    assert {:error, :invalid_context} = execute("profiles.list", %{"requester" => "127.0.0.1"})
    assert {:error, :invalid_context} = execute("profiles.list", %{"requester" => "::1"})
    assert {:ok, %{"status" => 401}} = execute("profiles.list", %{})
  end

  test "a transport operation cannot bypass the origin check", %{token: token} do
    assert {:error, :invalid_context} =
             execute("session.logout", %{
               "session" => token,
               "origin" => "https://attacker.example"
             })

    assert {:ok, _} = Session.verify_token(token)
  end

  test "revocation queued before a mutation is rechecked inside the writer", %{token: token} do
    writer = Process.whereis(ChatOverlay.Profiles)
    :ok = :sys.suspend(writer)

    try do
      revoke = Task.async(fn -> Session.revoke_token(token) end)
      assert queued?(writer, 1, 50)

      rotate =
        Task.async(fn ->
          execute("profiles.rotate_capability", %{
            "session" => token,
            "handle" => "alice",
            "origin" => "https://overlay.example.test"
          })
        end)

      assert queued?(writer, 2, 50)
      :ok = :sys.resume(writer)
      assert :ok = Task.await(revoke)
      assert {:ok, %{"status" => 422}} = Task.await(rotate)
      assert ChatOverlay.Config.profile("alice")["capability_token_hash"] == nil
    after
      :sys.resume(writer)
    end
  end

  test "public profile projection excludes encrypted and unknown account fields" do
    profile =
      ChatOverlay.Config.profile("alice")
      |> Map.put("linked_accounts", %{
        "twitch" => %{
          "user_id" => "alice-id",
          "encrypted_tokens" => "synthetic-ciphertext",
          "future_private_field" => "synthetic"
        }
      })

    public = ChatOverlay.Profiles.public_summary(profile)
    assert public["linked_accounts"]["twitch"] == %{"linked" => true, "user_id" => "alice-id"}
    refute Map.has_key?(public, "capability_token_hash")
  end

  defp queued?(_, _, 0), do: false

  defp queued?(pid, count, attempts) do
    {:message_queue_len, size} = Process.info(pid, :message_queue_len)

    if size >= count,
      do: true,
      else:
        (
          Process.sleep(5)
          queued?(pid, count, attempts - 1)
        )
  end
end
