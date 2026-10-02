defmodule ChatOverlay.ProfileStorage do
  @moduledoc "Atomic, private replacement of the bounded operator profile document."
  @max_bytes 65_536

  def write(path, profiles) do
    json = ChatOverlay.JSON.encode(%{"profiles" => profiles})
    dir = Path.dirname(path)

    cond do
      not File.dir?(dir) -> {:error, {:directory_not_found, dir}}
      byte_size(json) > @max_bytes -> {:error, :profile_document_too_large}
      true -> replace(path, dir, json)
    end
  rescue
    _ -> {:error, {:persist_failed, :invalid_document}}
  end

  defp replace(path, dir, json) do
    staging =
      Path.join(
        dir,
        ".profiles-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    case File.mkdir(staging) do
      :ok ->
        tmp = Path.join(staging, "document")

        try do
          with :ok <- File.chmod(staging, 0o700),
               :ok <- write_private(tmp, json),
               :ok <- File.rename(tmp, path) do
            :ok
          else
            {:error, reason} -> {:error, {:persist_failed, reason}}
          end
        after
          File.rm(tmp)
          File.rmdir(staging)
        end

      {:error, reason} ->
        {:error, {:persist_failed, reason}}
    end
  end

  defp write_private(path, json) do
    with {:ok, file} <- File.open(path, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600),
             :ok <- IO.binwrite(file, json),
             :ok <- :file.sync(file) do
          :ok
        end
      after
        File.close(file)
      end
    end
  end
end
