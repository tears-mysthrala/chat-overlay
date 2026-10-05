defmodule ChatOverlay.Recovery do
  @moduledoc "Offline encrypted backups and staged key rotation; never mutates the running application."
  alias ChatOverlay.{Config, Crypto, JSON, MediaLedger}
  @aad "chat-overlay-profile-backup:v1:"
  @max_bundle 131_072

  def backup(source, key_path, output) do
    with {:ok, key} <- read_key(key_path),
         {:ok, document} <- read_document(source),
         :ok <- verify_credentials(document, key),
         {:ok, bundle} <- seal(document, key) do
      write_new(output, bundle)
    end
  end

  def restore(source, key_path, output) do
    with {:ok, key} <- read_key(key_path),
         {:ok, document} <- unseal(source, key),
         :ok <- verify_credentials(document, key) do
      write_new(output, JSON.encode(document))
    end
  end

  # Produces an encrypted backup under the new key. Restore it to a new path and
  # explicitly stop/cut over the service; no online key or environment mutation.
  def rotate(source, old_key_path, new_key_path, output) do
    with {:ok, old_key} <- read_key(old_key_path),
         {:ok, new_key} <- read_key(new_key_path),
         true <- old_key != new_key || {:error, :keys_must_differ},
         {:ok, document} <- unseal(source, old_key),
         {:ok, document} <- rotate_credentials(document, old_key, new_key),
         {:ok, bundle} <- seal(document, new_key) do
      write_new(output, bundle)
    end
  end

  def key_id(key), do: Crypto.hash_token("recovery-key-id:v1:" <> key)

  defp read_key(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and Bitwise.band(stat.mode, 0o077) == 0,
         true <- stat.size in 32..4096,
         {:ok, key} <- File.read(path),
         true <- byte_size(key) in 32..4096 and not String.contains?(key, ["\n", "\r", <<0>>]) do
      {:ok, key}
    else
      _ -> {:error, :invalid_or_nonprivate_key_file}
    end
  end

  defp read_document(path) do
    {:ok, Config.load_document!(path)}
  rescue
    _ -> {:error, :invalid_document}
  end

  defp valid_document(document) do
    with true <- is_map(document) and byte_size(JSON.encode(document)) <= 65_536,
         true <- Enum.all?(Map.keys(document), &(&1 in ["profiles", "media_objects"])),
         {:ok, _} <- Config.validate(document["profiles"]),
         true <- MediaLedger.valid?(Map.get(document, "media_objects", [])) do
      {:ok, document}
    else
      _ -> {:error, :invalid_document}
    end
  end

  defp seal(document, key) do
    id = key_id(key)

    with {:ok, document} <- valid_document(document),
         {:ok, payload} <- Crypto.encrypt_aead(JSON.encode(document), key, @aad <> id) do
      {:ok, JSON.encode(%{"version" => 1, "key_id" => id, "payload" => payload})}
    end
  end

  defp unseal(path, key) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.size <= @max_bundle,
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= @max_bundle,
         {:ok, %{"version" => 1, "key_id" => id, "payload" => payload} = envelope} <-
           JSON.decode(bytes),
         true <- map_size(envelope) == 3 and id == key_id(key),
         {:ok, json} <- Crypto.decrypt_aead(payload, key, @aad <> id),
         {:ok, document} <- JSON.decode(json),
         {:ok, document} <- valid_document(document) do
      {:ok, document}
    else
      _ -> {:error, :invalid_backup_or_key}
    end
  end

  defp verify_credentials(document, key) do
    case rotate_credentials(document, key, key) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_credentials_or_key}
    end
  end

  defp rotate_credentials(document, old_key, new_key) do
    result =
      Enum.reduce_while(document["profiles"], {:ok, []}, fn profile, {:ok, acc} ->
        accounts = profile["linked_accounts"] || %{}

        rotated =
          Enum.reduce_while(accounts, {:ok, %{}}, fn {provider, account}, {:ok, linked} ->
            aad = "token:#{profile["handle"]}:#{provider}"

            with {:ok, plaintext} <-
                   Crypto.decrypt_aead(account["encrypted_tokens"], old_key, aad),
                 {:ok, tokens} when is_map(tokens) <- JSON.decode(plaintext),
                 {:ok, encrypted} <- Crypto.encrypt_aead(plaintext, new_key, aad) do
              {:cont,
               {:ok, Map.put(linked, provider, Map.put(account, "encrypted_tokens", encrypted))}}
            else
              _ -> {:halt, {:error, :invalid_credentials_or_key}}
            end
          end)

        case rotated do
          {:ok, linked} ->
            updated =
              if Map.has_key?(profile, "linked_accounts"),
                do: Map.put(profile, "linked_accounts", linked),
                else: profile

            {:cont, {:ok, [updated | acc]}}

          error ->
            {:halt, error}
        end
      end)

    case result do
      {:ok, profiles} -> valid_document(Map.put(document, "profiles", Enum.reverse(profiles)))
      error -> error
    end
  end

  # A private staging directory protects contents before their first write.
  # Hard-link publication is atomic and refuses any existing destination, even a
  # symlink. Both names are on the same filesystem. No in-place overwrite.
  defp write_new(path, contents) do
    dir =
      Path.join(
        Path.dirname(path),
        ".recovery-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    case File.mkdir(dir) do
      :ok ->
        temporary = Path.join(dir, "payload")

        try do
          with :ok <- File.chmod(dir, 0o700),
               {:ok, io} <- File.open(temporary, [:write, :binary, :exclusive]) do
            result =
              try do
                with :ok <- File.chmod(temporary, 0o600),
                     :ok <- IO.binwrite(io, contents),
                     :ok <- :file.sync(io),
                     do: :ok
              after
                File.close(io)
              end

            with :ok <- result, :ok <- File.ln(temporary, path), do: :ok
          end
        after
          File.rm(temporary)
          File.rmdir(dir)
        end

      error ->
        error
    end
  end
end
