defmodule ChatOverlay.PostgresTransfer do
  @moduledoc "Operator-only offline copy import/export; never called from HTTP or startup."
  alias ChatOverlay.{Config, Postgres, ProfileStorage}
  @empty %{"profiles" => [], "media_objects" => []}

  def import_copy!(path) do
    document = Config.load_document!(path)
    # Refuse overwrite; rollback before cutover keeps the original JSON copy intact.
    true = Postgres.export!() == @empty
    :ok = Postgres.replace(@empty, document)
    exported = Postgres.export!()
    true = Postgres.canonical(document) == exported

    %{
      profiles: length(exported["profiles"]),
      objects: length(exported["media_objects"]),
      digest: Postgres.digest(exported)
    }
  end

  def export_copy!(path) do
    # A fresh output avoids accidentally overwriting the pre-cutover backup.
    false = File.exists?(path)
    document = Postgres.export!()
    :ok = ProfileStorage.write_new(path, document["profiles"], document["media_objects"])
    reloaded = Config.load_document!(path)
    true = Postgres.canonical(reloaded) == document

    %{
      profiles: length(reloaded["profiles"]),
      objects: length(reloaded["media_objects"]),
      digest: Postgres.digest(reloaded)
    }
  end
end
