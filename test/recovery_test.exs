defmodule ChatOverlay.RecoveryTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.{Config, Crypto, JSON, Recovery, Session}

  setup do
    dir = Path.join(System.tmp_dir!(), "recovery-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    old = Base.encode16(:crypto.strong_rand_bytes(32))
    new = Base.encode16(:crypto.strong_rand_bytes(32))
    old_path = Path.join(dir, "old.key")
    new_path = Path.join(dir, "new.key")
    File.write!(old_path, old)
    File.write!(new_path, new)
    File.chmod!(old_path, 0o600)
    File.chmod!(new_path, 0o600)
    capability = Crypto.generate_capability_token()

    profiles =
      Enum.map(["alice", "bob"], fn handle ->
        {:ok, encrypted} =
          Crypto.encrypt_aead(
            JSON.encode(%{
              "access_token" => "synthetic-#{handle}",
              "refresh_token" => "synthetic-refresh-#{handle}"
            }),
            old,
            "token:#{handle}:twitch"
          )

        %{
          "handle" => handle,
          "sources" => [%{"platform" => "twitch", "channel" => handle, "mode" => "demo"}],
          "can_upload" => handle == "alice",
          "capability_token_hash" => Crypto.hash_token(capability),
          "linked_accounts" => %{
            "twitch" => %{
              "encrypted_tokens" => encrypted,
              "user_id" => handle,
              "account_version" => 7,
              "linked" => true
            }
          }
        }
      end)

    source = Path.join(dir, "source.json")

    document = %{
      "profiles" => profiles,
      "media_objects" => [
        %{
          "handle" => "alice",
          "key" => "alice/audio/pending.mp3",
          "size" => 100,
          "category" => "audio",
          "mime" => "audio/mpeg",
          "expires_at" => System.system_time(:second) + 300,
          "state" => "pending"
        }
      ]
    }

    File.write!(source, JSON.encode(document))
    on_exit(fn -> File.rm_rf!(dir) end)

    %{
      dir: dir,
      old: old,
      new: new,
      old_path: old_path,
      new_path: new_path,
      source: source,
      document: document,
      capability: capability,
      backup: Path.join(dir, "backup.aead"),
      rotated: Path.join(dir, "rotated.aead"),
      restored: Path.join(dir, "restored.json")
    }
  end

  test "encrypted backup and isolated restore preserve profiles, permissions and inventory", c do
    assert :ok = Recovery.backup(c.source, c.old_path, c.backup)
    encrypted = File.read!(c.backup)
    refute encrypted =~ "alice"
    refute encrypted =~ "synthetic"
    assert Bitwise.band(File.stat!(c.backup).mode, 0o777) == 0o600
    assert :ok = Recovery.restore(c.backup, c.old_path, c.restored)
    assert Config.load_document!(c.restored) == c.document
    assert Bitwise.band(File.stat!(c.restored).mode, 0o777) == 0o600
  end

  test "rotation reencrypts every credential with profile-bound AAD and preserves permissions",
       c do
    source_bytes = File.read!(c.source)
    assert :ok = Recovery.backup(c.source, c.old_path, c.backup)
    assert :ok = Recovery.rotate(c.backup, c.old_path, c.new_path, c.rotated)
    assert :ok = Recovery.restore(c.rotated, c.new_path, c.restored)
    rotated = Config.load_document!(c.restored)

    for profile <- rotated["profiles"] do
      handle = profile["handle"]
      ciphertext = profile["linked_accounts"]["twitch"]["encrypted_tokens"]
      assert {:ok, plaintext} = Crypto.decrypt_aead(ciphertext, c.new, "token:#{handle}:twitch")
      assert plaintext =~ "synthetic-#{handle}"
      assert {:error, _} = Crypto.decrypt_aead(ciphertext, c.old, "token:#{handle}:twitch")
      assert {:error, _} = Crypto.decrypt_aead(ciphertext, c.new, "token:someone-else:twitch")
      assert profile["can_upload"] == (handle == "alice")
      assert profile["linked_accounts"]["twitch"]["account_version"] == 7
      assert Crypto.verify_token(c.capability, profile["capability_token_hash"])
    end

    assert rotated["media_objects"] == c.document["media_objects"]
    assert File.read!(c.source) == source_bytes

    assert {:error, _} =
             Recovery.restore(c.rotated, c.old_path, Path.join(c.dir, "wrong-key.json"))

    # Sessions and in-flight OAuth/upload AEAD tokens share the master key.
    assert {:ok, session} = Session.create_token(%{"handle" => "alice"}, key: c.old)
    assert {:error, _} = Session.verify_token(session, key: c.new)
  end

  test "wrong key, corruption and interrupted backup cannot create a restore output", c do
    assert :ok = Recovery.backup(c.source, c.old_path, c.backup)
    assert {:error, _} = Recovery.restore(c.backup, c.new_path, c.restored)
    refute File.exists?(c.restored)
    File.write!(c.backup, binary_part(File.read!(c.backup), 0, 80))
    assert {:error, _} = Recovery.restore(c.backup, c.old_path, c.restored)
    refute File.exists?(c.restored)
  end

  test "credential integrity failure aborts backup without leaking plaintext", c do
    [first, second] = c.document["profiles"]

    corrupted =
      put_in(
        first,
        ["linked_accounts", "twitch", "encrypted_tokens"],
        second["linked_accounts"]["twitch"]["encrypted_tokens"]
      )

    File.write!(c.source, JSON.encode(%{c.document | "profiles" => [corrupted, second]}))
    assert {:error, :invalid_credentials_or_key} = Recovery.backup(c.source, c.old_path, c.backup)
    refute File.exists?(c.backup)
  end

  test "existing files, symlinks and disk path failures never overwrite source", c do
    before = File.read!(c.source)
    assert {:error, :eexist} = Recovery.backup(c.source, c.old_path, c.source)
    File.ln_s!(c.source, c.backup)
    assert {:error, :eexist} = Recovery.backup(c.source, c.old_path, c.backup)

    assert {:error, :enoent} =
             Recovery.backup(c.source, c.old_path, Path.join([c.dir, "missing", "backup"]))

    assert File.read!(c.source) == before
    refute Enum.any?(File.ls!(c.dir), &String.starts_with?(&1, ".recovery-"))
  end

  test "nonprivate key, unsupported bundle version and same-key rotation fail closed", c do
    File.chmod!(c.old_path, 0o644)

    assert {:error, :invalid_or_nonprivate_key_file} =
             Recovery.backup(c.source, c.old_path, c.backup)

    File.chmod!(c.old_path, 0o600)
    assert :ok = Recovery.backup(c.source, c.old_path, c.backup)

    assert {:error, :keys_must_differ} =
             Recovery.rotate(c.backup, c.old_path, c.old_path, c.rotated)

    {:ok, envelope} = JSON.decode(File.read!(c.backup))
    File.write!(c.backup, JSON.encode(Map.put(envelope, "version", 2)))
    assert {:error, :invalid_backup_or_key} = Recovery.restore(c.backup, c.old_path, c.restored)
  end
end
