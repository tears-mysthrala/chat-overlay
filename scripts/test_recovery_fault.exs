alias ChatOverlay.{Crypto, JSON, Recovery}

case System.fetch_env!("RECOVERY_TEST_PHASE") do
  "prepare" ->
    File.mkdir_p!("/fixture")
    key = Base.encode16(:crypto.strong_rand_bytes(32))
    File.write!("/fixture/key", key)
    File.chmod!("/fixture/key", 0o600)

    {:ok, encrypted} =
      Crypto.encrypt_aead(
        JSON.encode(%{"access_token" => "synthetic"}),
        key,
        "token:alice:twitch"
      )

    document = %{
      "profiles" => [
        %{
          "handle" => "alice",
          "sources" => [%{"platform" => "twitch", "channel" => "alice", "mode" => "demo"}],
          "linked_accounts" => %{
            "twitch" => %{
              "user_id" => "alice",
              "linked" => true,
              "account_version" => 1,
              "encrypted_tokens" => encrypted
            }
          }
        }
      ],
      "media_objects" => []
    }

    File.write!("/fixture/source", JSON.encode(document))
    :ok = Recovery.backup("/fixture/source", "/fixture/key", "/fixture/baseline")

  "write" ->
    result = Recovery.backup("/fixture/source", "/fixture/key", "/faultout/backup")

    case System.fetch_env!("RECOVERY_FAULT_MODE") do
      "eio" -> {:error, :eio} = result
      "kill" -> raise "fault did not kill writer: #{inspect(result)}"
    end

  "check" ->
    false = File.exists?("/faultout/backup")
    mode = System.fetch_env!("RECOVERY_FAULT_MODE")

    case {mode, File.ls!("/faultout")} do
      {"eio", []} ->
        :ok

      {"kill", [staging]} ->
        true = String.starts_with?(staging, ".recovery-")
        {:ok, stat} = File.stat("/faultout/" <> staging)
        0o700 = Bitwise.band(stat.mode, 0o777)
        # SIGKILL bypasses cleanup; the private orphan is never a published backup.
        File.rm_rf!("/faultout/" <> staging)

      other ->
        raise "unexpected staging: #{inspect(other)}"
    end

    :ok = Recovery.restore("/fixture/baseline", "/fixture/key", "/fixture/restored")
    {:ok, original} = File.read!("/fixture/source") |> JSON.decode()
    {:ok, ^original} = File.read!("/fixture/restored") |> JSON.decode()
    :ok = Recovery.backup("/fixture/source", "/fixture/key", "/faultout/retry")
    IO.puts("Recovery #{mode}: PASS; no incomplete output, baseline restores, retry succeeds")
end
