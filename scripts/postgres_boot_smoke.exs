# Full product startup/restart against the same isolated synthetic PostgreSQL.
{:ok, _} = Application.ensure_all_started(:postgrex)

common = [
  hostname: System.fetch_env!("PG_LOCAL_HOST"),
  database: "overlay_synthetic",
  port: 5432,
  pool_size: 1,
  ssl: false
]

runtime = common ++ [username: "overlay_runtime", password: "synthetic-runtime"]
bootstrap = common ++ [username: "overlay_bootstrap", password: "synthetic-bootstrap"]
{:ok, writer} = Postgrex.start_link(runtime ++ [name: ChatOverlay.Postgres.Runtime])
{:ok, reader} = Postgrex.start_link(bootstrap ++ [name: ChatOverlay.Postgres.Bootstrap])

document = %{
  "profiles" => [
    %{
      "handle" => "booted",
      "sources" => [%{"platform" => "twitch", "channel" => "booted", "mode" => "demo"}]
    }
  ],
  "media_objects" => []
}

:ok = ChatOverlay.Postgres.replace(ChatOverlay.Postgres.export!(), document)
GenServer.stop(reader)
GenServer.stop(writer)
Application.put_env(:chat_overlay, :postgres_runtime, runtime)
Application.put_env(:chat_overlay, :postgres_bootstrap, bootstrap)
Application.put_env(:chat_overlay, :persistence_backend, :postgres)
Application.put_env(:chat_overlay, :profiles, [])
Application.put_env(:chat_overlay, :profiles_path, "/nonexistent/no-json-fallback.json")
Application.put_env(:chat_overlay, :http, false)
{:ok, _} = Application.ensure_all_started(:chat_overlay)
true = ChatOverlay.Config.profiles() == document["profiles"]
true = is_pid(GenServer.whereis(ChatOverlay.Store.name("booted")))
{:ok, _} = ChatOverlay.Profiles.update_upload_quota("booted", 321)
:ok = Application.stop(:chat_overlay)
Application.put_env(:chat_overlay, :profiles, [])
{:ok, _} = Application.ensure_all_started(:chat_overlay)
321 = ChatOverlay.Config.profile("booted")["storage_used_bytes"]
true = is_pid(GenServer.whereis(ChatOverlay.Store.name("booted")))
false = File.exists?("/nonexistent/no-json-fallback.json")
:ok = Application.stop(:chat_overlay)
IO.puts("Full PostgreSQL product boot, durable mutation and restart: PASS")
