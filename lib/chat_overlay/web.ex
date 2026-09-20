defmodule ChatOverlay.Web do
  @moduledoc "Closed routing; no public profile index, ingestion or administration."
  @behaviour Plug
  alias ChatOverlay.{Config, HTTP}
  def init(opts), do: opts

  def call(conn, _) do
    case {conn.method, conn.path_info} do
      {"POST", ["hooks", "kick"]} ->
        ChatOverlay.KickWebhook.call(conn)

      {"GET", ["events", handle]} ->
        ChatOverlay.Stream.call(conn, handle)

      {method, _} when method not in ["GET", "HEAD"] ->
        reply(conn, 405, "text/plain", "Method not allowed")

      {_, []} ->
        asset(conn, "index.html")

      {_, ["favicon.ico"]} ->
        reply(conn, 204, "image/x-icon", "")

      {_, ["health", "live"]} ->
        reply(conn, 200, "text/plain", "ok")

      {_, ["health", "ready"]} ->
        ready =
          Process.whereis(ChatOverlay.Admission) &&
            Enum.all?(Config.profiles(), fn p ->
              Registry.lookup(ChatOverlay.Registry, {:store, p["handle"]}) != []
            end)

        reply(
          conn,
          if(ready, do: 200, else: 503),
          "text/plain",
          if(ready, do: "ready", else: "unavailable")
        )

      {_, ["assets", file]} when file in ["app.js", "app.css"] ->
        asset(conn, file)

      {_, [view, handle]} when view in ["reader", "overlay"] ->
        case Config.profile(handle) do
          nil ->
            reply(conn, 404, "text/plain", "Not found")

          profile ->
            body = File.read!(Application.app_dir(:chat_overlay, "priv/static/chat.html"))
            demo = Enum.any?(profile["sources"], &(&1["mode"] == "demo"))

            reply(
              conn,
              200,
              "text/html; charset=utf-8",
              String.replace(body, "__DEMO__", to_string(demo))
            )
        end

      _ ->
        reply(conn, 404, "text/plain", "Not found")
    end
  end

  def reply(conn, code, type, body),
    do:
      conn |> Plug.Conn.merge_resp_headers(HTTP.headers(type)) |> Plug.Conn.send_resp(code, body)

  defp asset(conn, file) do
    type =
      case Path.extname(file) do
        ".html" -> "text/html; charset=utf-8"
        ".css" -> "text/css; charset=utf-8"
        ".js" -> "text/javascript; charset=utf-8"
      end

    reply(conn, 200, type, File.read!(Application.app_dir(:chat_overlay, "priv/static/#{file}")))
  end
end
