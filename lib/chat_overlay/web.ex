defmodule ChatOverlay.Web do
  @moduledoc "Closed routing; creator dashboard, dynamic profiles API, and chat views."
  @behaviour Plug
  alias ChatOverlay.{Config, HTTP}
  def init(opts), do: opts

  def call(conn, _) do
    case {conn.method, conn.path_info} do
      {"POST", ["hooks", "kick"]} ->
        ChatOverlay.KickWebhook.call(conn)

      {"GET", ["events", handle]} ->
        ChatOverlay.Stream.call(conn, handle)

      {"GET", ["api", "profiles"]} ->
        api_list_profiles(conn)

      {"POST", ["api", "profiles"]} ->
        api_create_profile(conn)

      {"POST", ["api", "resolve"]} ->
        api_resolve(conn)

      {"DELETE", ["api", "profiles", handle]} ->
        api_delete_profile(conn, handle)

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

  defp api_list_profiles(conn) do
    data = %{"profiles" => ChatOverlay.Profiles.list()}
    reply(conn, 200, "application/json", ChatOverlay.JSON.encode(data))
  end

  defp api_create_profile(conn) do
    case Plug.Conn.read_body(conn, length: 65_536, read_length: 8192, read_timeout: 4000) do
      {:ok, body, conn} ->
        case ChatOverlay.JSON.decode(body) do
          {:ok, params} when is_map(params) ->
            case ChatOverlay.Profiles.create_or_update(params) do
              {:ok, profile} ->
                resp = %{
                  "ok" => true,
                  "profile" => profile,
                  "reader_url" => "/reader/#{profile["handle"]}",
                  "overlay_url" => "/overlay/#{profile["handle"]}"
                }

                reply(conn, 201, "application/json", ChatOverlay.JSON.encode(resp))

              {:error, reason} ->
                reply(
                  conn,
                  422,
                  "application/json",
                  ChatOverlay.JSON.encode(%{"ok" => false, "error" => format_error(reason)})
                )
            end

          _ ->
            reply(
              conn,
              400,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Cuerpo JSON inválido"})
            )
        end

      _ ->
        reply(
          conn,
          413,
          "application/json",
          ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Petición demasiado grande"})
        )
    end
  end

  defp api_resolve(conn) do
    case Plug.Conn.read_body(conn, length: 65_536, read_length: 8192, read_timeout: 4000) do
      {:ok, body, conn} ->
        case ChatOverlay.JSON.decode(body) do
          {:ok, %{"target" => target} = params} when is_binary(target) ->
            opts = if params["platform"], do: [platform: params["platform"]], else: []

            case ChatOverlay.Profiles.resolve_target(target, opts) do
              {:ok, source, suggested} ->
                resp = %{
                  "ok" => true,
                  "source" => source,
                  "suggested_handle" => suggested
                }

                reply(conn, 200, "application/json", ChatOverlay.JSON.encode(resp))

              {:error, reason} ->
                reply(
                  conn,
                  422,
                  "application/json",
                  ChatOverlay.JSON.encode(%{"ok" => false, "error" => format_error(reason)})
                )
            end

          _ ->
            reply(
              conn,
              400,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Campo 'target' requerido"})
            )
        end

      _ ->
        reply(
          conn,
          413,
          "application/json",
          ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Petición demasiado grande"})
        )
    end
  end

  defp api_delete_profile(conn, handle) do
    case ChatOverlay.Profiles.delete(handle) do
      :ok ->
        reply(conn, 200, "application/json", ChatOverlay.JSON.encode(%{"ok" => true}))

      {:error, :not_found} ->
        reply(
          conn,
          404,
          "application/json",
          ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Perfil no encontrado"})
        )

      {:error, reason} ->
        reply(
          conn,
          422,
          "application/json",
          ChatOverlay.JSON.encode(%{"ok" => false, "error" => format_error(reason)})
        )
    end
  end

  defp format_error(:invalid_twitch_channel), do: "Nombre o URL de Twitch no válido."
  defp format_error(:user_not_found), do: "No se encontró el canal o usuario en Twitch."

  defp format_error(:missing_twitch_credentials),
    do: "Falta configurar la variable CHAT_TWITCH_TOKEN para Twitch."

  defp format_error({:twitch_api_error, status}),
    do: "Error al consultar Twitch (código #{status})."

  defp format_error(:invalid_youtube_target), do: "URL, handle o ID de YouTube no válido."
  defp format_error(:channel_not_found), do: "Canal de YouTube no encontrado."

  defp format_error(:no_active_stream),
    do: "El canal de YouTube no tiene una emisión en directo activa ahora mismo."

  defp format_error(:no_active_live_chat),
    do: "El directo de YouTube no tiene un chat en vivo habilitado."

  defp format_error(:missing_youtube_credentials),
    do: "Falta configurar la variable CHAT_YOUTUBE_TOKEN para YouTube."

  defp format_error({:youtube_api_error, status}),
    do: "Error al consultar YouTube (código #{status})."

  defp format_error(:invalid_handle),
    do:
      "El nombre de perfil debe contener entre 1 y 40 caracteres (letras minúsculas, números, guiones)."

  defp format_error(:invalid_configuration),
    do: "Configuración inválida (se superó el límite de perfiles o fuentes)."

  defp format_error(:upstream_unavailable),
    do: "No se pudo contactar con la API remota. Revisa la conexión."

  defp format_error(:missing_target_or_sources),
    do: "Debes especificar un canal o URL a resolver."

  defp format_error(other), do: "Error: #{inspect(other)}"
end
