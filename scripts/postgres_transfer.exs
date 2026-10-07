# Run offline with --no-start: HTTP, sources, cleanup and token workers stay stopped.
{:ok, _} = Application.ensure_all_started(:postgrex)
runtime = Application.fetch_env!(:chat_overlay, :postgres_runtime)
bootstrap = Application.fetch_env!(:chat_overlay, :postgres_bootstrap)
{:ok, writer} = Postgrex.start_link(runtime ++ [name: ChatOverlay.Postgres.Runtime])
{:ok, reader} = Postgrex.start_link(bootstrap ++ [name: ChatOverlay.Postgres.Bootstrap])

try do
  :ok = ChatOverlay.Postgres.validate_runtime!()

  result =
    case System.argv() do
      ["import-copy", path] -> ChatOverlay.PostgresTransfer.import_copy!(path)
      ["export-copy", path] -> ChatOverlay.PostgresTransfer.export_copy!(path)
      _ -> raise "Expected import-copy/export-copy and a private offline copy path"
    end

  IO.inspect(result, label: "Validated transfer")
after
  GenServer.stop(reader)
  GenServer.stop(writer)
end
