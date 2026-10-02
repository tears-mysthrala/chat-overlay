# Offline only: mix run --no-start scripts/recovery.exs <command> <paths...>
result =
  case System.argv() do
    ["backup", source, key, output] ->
      ChatOverlay.Recovery.backup(source, key, output)

    ["restore", source, key, output] ->
      ChatOverlay.Recovery.restore(source, key, output)

    ["rotate", source, old_key, new_key, output] ->
      ChatOverlay.Recovery.rotate(source, old_key, new_key, output)

    _ ->
      {:error, :usage}
  end

case result do
  :ok ->
    IO.puts("Recovery artifact prepared. No running service or key was changed.")

  {:error, :usage} ->
    IO.puts(
      :stderr,
      "Usage: recovery.exs backup|restore INPUT KEY_FILE NEW_OUTPUT; rotate BACKUP OLD_KEY_FILE NEW_KEY_FILE NEW_BACKUP"
    )

    System.halt(2)

  {:error, _} ->
    IO.puts(
      :stderr,
      "Recovery failed; check private key files, input integrity and a new writable output path. No secrets are printed."
    )

    System.halt(1)
end
