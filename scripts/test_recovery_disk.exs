# Run with /recovery-faults mounted as a 4KiB tmpfs; synthetic data only.
alias ChatOverlay.{Crypto, JSON, Recovery}

dir = Path.join(System.tmp_dir!(), "recovery-disk-#{System.unique_integer([:positive])}")
File.mkdir!(dir)
key = Base.encode16(:crypto.strong_rand_bytes(32))
key_path = Path.join(dir, "key")
source = Path.join(dir, "source.json")
output = "/recovery-faults/backup.aead"

try do
  File.write!(key_path, key)
  File.chmod!(key_path, 0o600)

  {:ok, encrypted} =
    Crypto.encrypt_aead(
      JSON.encode(%{"access_token" => String.duplicate("synthetic", 2048)}),
      key,
      "token:alice:twitch"
    )

  document = %{
    "profiles" => [
      %{
        "handle" => "alice",
        "sources" => [%{"platform" => "twitch", "channel" => "alice", "mode" => "demo"}],
        "can_upload" => false,
        "capability_token_hash" => Crypto.hash_token(Crypto.generate_capability_token()),
        "linked_accounts" => %{
          "twitch" => %{
            "encrypted_tokens" => encrypted,
            "user_id" => "alice",
            "account_version" => 1,
            "linked" => true
          }
        }
      }
    ],
    "media_objects" => []
  }

  bytes = JSON.encode(document)
  File.write!(source, bytes)
  {:error, :enospc} = Recovery.backup(source, key_path, output)
  false = File.exists?(output)
  [] = File.ls!("/recovery-faults")
  ^bytes = File.read!(source)
  IO.puts("Recovery staging ENOSPC: PASS; no output, staging cleaned, source unchanged")
after
  File.rm_rf!(dir)
end
