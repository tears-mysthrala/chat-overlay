defmodule ChatOverlay.Web do
  @moduledoc "Closed routing; creator dashboard, dynamic profiles API, and chat views."
  @behaviour Plug
  alias ChatOverlay.{Config, HTTP, Session}
  def init(opts), do: opts

  def call(conn, _) do
    case {conn.method, conn.path_info} do
      {"POST", ["hooks", "kick"]} ->
        ChatOverlay.KickWebhook.call(conn)

      {"GET", ["events", handle]} ->
        ChatOverlay.Stream.call(conn, handle)

      {"GET", ["api", "oauth", "authorize", provider]} ->
        api_oauth_authorize(conn, provider)

      {"GET", ["oauth", "callback", provider]} ->
        oauth_callback(conn, provider)

      {"GET", ["api", "auth", "me"]} ->
        api_auth_me(conn)

      {"GET", ["api", "session"]} ->
        api_auth_me(conn)

      {"POST", ["api", "auth", "logout"]} ->
        with true <- allowed_origin?(conn) do
          api_auth_logout(conn)
        else
          :bad_origin ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Origen no permitido"})
            )
        end

      {"GET", ["api", "profiles"]} ->
        api_list_profiles(conn)

      {"POST", ["api", "profiles"]} ->
        with true <- allowed_origin?(conn),
             true <- json_content_type?(conn) do
          api_create_profile(conn)
        else
          :bad_origin ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Origen no permitido"})
            )

          :bad_content_type ->
            reply(
              conn,
              415,
              "application/json",
              ChatOverlay.JSON.encode(%{
                "ok" => false,
                "error" => "Content-Type debe ser application/json"
              })
            )
        end

      {"POST", ["api", "resolve"]} ->
        with true <- allowed_origin?(conn),
             true <- json_content_type?(conn) do
          api_resolve(conn)
        else
          :bad_origin ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Origen no permitido"})
            )

          :bad_content_type ->
            reply(
              conn,
              415,
              "application/json",
              ChatOverlay.JSON.encode(%{
                "ok" => false,
                "error" => "Content-Type debe ser application/json"
              })
            )
        end

      {"DELETE", ["api", "profiles", handle]} ->
        with true <- allowed_origin?(conn),
             :ok <- Session.authorize(conn, handle) do
          api_delete_profile(conn, handle)
        else
          :bad_origin ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Origen no permitido"})
            )

          {:error, :unauthorized} ->
            reply(
              conn,
              401,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "No autorizado"})
            )

          {:error, :forbidden} ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{
                "ok" => false,
                "error" => "Acceso no autorizado al perfil solicitado"
              })
            )
        end

      {"POST", ["api", "profiles", handle, "sync-youtube"]} ->
        with true <- allowed_origin?(conn),
             :ok <- Session.authorize(conn, handle) do
          api_sync_youtube(conn, handle)
        else
          :bad_origin ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Origen no permitido"})
            )

          {:error, :unauthorized} ->
            reply(
              conn,
              401,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "No autorizado"})
            )

          {:error, :forbidden} ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{
                "ok" => false,
                "error" => "Acceso no autorizado al perfil solicitado"
              })
            )
        end

      {"POST", ["api", "profiles", handle, "token", "regenerate"]} ->
        with true <- allowed_origin?(conn),
             :ok <- Session.authorize(conn, handle) do
          api_regenerate_token(conn, handle)
        else
          :bad_origin ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Origen no permitido"})
            )

          {:error, :unauthorized} ->
            reply(
              conn,
              401,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "No autorizado"})
            )

          {:error, :forbidden} ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{
                "ok" => false,
                "error" => "Acceso no autorizado al perfil solicitado"
              })
            )
        end

      {"POST", ["api", "media", "presign"]} ->
        with true <- allowed_origin?(conn),
             true <- json_content_type?(conn) do
          api_media_presign(conn)
        else
          :bad_origin ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Origen no permitido"})
            )

          :bad_content_type ->
            reply(
              conn,
              415,
              "application/json",
              ChatOverlay.JSON.encode(%{
                "ok" => false,
                "error" => "Content-Type debe ser application/json"
              })
            )
        end

      {"POST", ["api", "profiles", handle, "media"]} ->
        with true <- allowed_origin?(conn),
             true <- json_content_type?(conn),
             :ok <- Session.authorize(conn, handle) do
          api_update_media(conn, handle)
        else
          :bad_origin ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Origen no permitido"})
            )

          :bad_content_type ->
            reply(
              conn,
              415,
              "application/json",
              ChatOverlay.JSON.encode(%{
                "ok" => false,
                "error" => "Content-Type debe ser application/json"
              })
            )

          {:error, :unauthorized} ->
            reply(
              conn,
              401,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "No autorizado"})
            )

          {:error, :forbidden} ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{
                "ok" => false,
                "error" => "Acceso no autorizado al perfil solicitado"
              })
            )
        end

      {"POST", ["api", "profiles", handle, "unlink", provider]} ->
        with true <- allowed_origin?(conn),
             :ok <- Session.authorize(conn, handle) do
          api_unlink_account(conn, handle, provider)
        else
          :bad_origin ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Origen no permitido"})
            )

          {:error, :unauthorized} ->
            reply(
              conn,
              401,
              "application/json",
              ChatOverlay.JSON.encode(%{"ok" => false, "error" => "No autorizado"})
            )

          {:error, :forbidden} ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{
                "ok" => false,
                "error" => "Acceso no autorizado al perfil solicitado"
              })
            )
        end

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

      {_, ["reader", handle]} ->
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

      {_, ["overlay", handle]} ->
        token = extract_token_from_conn(conn)

        case ChatOverlay.Profiles.verify_capability_token(handle, token) do
          {:ok, profile} ->
            body = File.read!(Application.app_dir(:chat_overlay, "priv/static/chat.html"))
            demo = Enum.any?(profile["sources"], &(&1["mode"] == "demo"))

            reply(
              conn,
              200,
              "text/html; charset=utf-8",
              String.replace(body, "__DEMO__", to_string(demo))
            )

          {:error, :unauthorized} ->
            reply(
              conn,
              401,
              "text/html; charset=utf-8",
              """
              <!doctype html>
              <html lang="es">
              <head><meta charset="utf-8"><title>401 No Autorizado</title><link rel="stylesheet" href="/assets/app.css"></head>
              <body class="unauthorized-body">
                <div class="unauthorized-card">
                  <h1>401 No Autorizado</h1>
                  <p>Esta fuente de OBS requiere un <strong>Capability Token</strong> válido.</p>
                  <p>Copia el enlace completo actualizado o regenera el enlace desde el Panel de Creador.</p>
                </div>
              </body>
              </html>
              """
            )

          {:error, :not_found} ->
            reply(conn, 404, "text/plain", "Not found")
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
    all_profiles = ChatOverlay.Profiles.list()

    case Session.scope_profiles(conn, all_profiles) do
      {:ok, profiles} ->
        data = %{"profiles" => profiles}
        reply(conn, 200, "application/json", ChatOverlay.JSON.encode(data))

      {:error, :unauthorized} ->
        reply(
          conn,
          401,
          "application/json",
          ChatOverlay.JSON.encode(%{"ok" => false, "error" => "No autorizado"})
        )
    end
  end

  defp api_create_profile(conn) do
    case Plug.Conn.read_body(conn, length: 65_536, read_length: 8192, read_timeout: 4000) do
      {:ok, body, conn} ->
        case ChatOverlay.JSON.decode(body) do
          {:ok, params} when is_map(params) ->
            case Session.authorize_profile_creation(conn, params) do
              :ok ->
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

              {:error, :unauthorized} ->
                reply(
                  conn,
                  401,
                  "application/json",
                  ChatOverlay.JSON.encode(%{"ok" => false, "error" => "No autorizado"})
                )

              {:error, :forbidden} ->
                reply(
                  conn,
                  403,
                  "application/json",
                  ChatOverlay.JSON.encode(%{
                    "ok" => false,
                    "error" => "Acceso no autorizado al perfil solicitado"
                  })
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
            base_opts = if params["platform"], do: [platform: params["platform"]], else: []
            opts = Keyword.put(base_opts, :with_meta, true)

            case ChatOverlay.Profiles.resolve_target(target, opts) do
              {:ok, sources, suggested, meta} when is_list(sources) ->
                resp = %{
                  "ok" => true,
                  "source" => hd(sources),
                  "sources" => sources,
                  "suggested_handle" => suggested,
                  "meta" => meta
                }

                reply(conn, 200, "application/json", ChatOverlay.JSON.encode(resp))

              {:ok, source, suggested} ->
                resp = %{
                  "ok" => true,
                  "source" => source,
                  "sources" => [source],
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

  defp api_sync_youtube(conn, handle) do
    case ChatOverlay.Profiles.sync_youtube(handle) do
      {:ok, profile} ->
        resp = %{
          "ok" => true,
          "profile" => profile,
          "message" => "Directo de YouTube sincronizado e incorporado al perfil."
        }

        reply(conn, 200, "application/json", ChatOverlay.JSON.encode(resp))

      {:error, :no_active_stream} ->
        reply(
          conn,
          422,
          "application/json",
          ChatOverlay.JSON.encode(%{
            "ok" => false,
            "error" =>
              "El canal de YouTube vinculado no tiene ninguna emisión en directo activa en este momento."
          })
        )

      {:error, :no_linked_youtube} ->
        reply(
          conn,
          422,
          "application/json",
          ChatOverlay.JSON.encode(%{
            "ok" => false,
            "error" => "No se encontró ningún canal de YouTube vinculado a este perfil."
          })
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

  defp json_content_type?(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [ct | _] ->
        if String.starts_with?(String.downcase(ct), "application/json"),
          do: true,
          else: :bad_content_type

      _ ->
        :bad_content_type
    end
  end

  defp allowed_origin?(conn) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] ->
        true

      [origin] ->
        uri = URI.parse(origin)
        host = uri.host || ""

        if host in ["localhost", "127.0.0.1", conn.host],
          do: true,
          else: :bad_origin

      _ ->
        :bad_origin
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

  defp format_error(:no_linked_youtube),
    do: "No se encontró ningún canal de YouTube vinculado a este perfil."

  defp format_error(:not_found), do: "Perfil no encontrado."

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

  defp format_error({:directory_not_found, _}),
    do: "No se pudo guardar el cambio. Revisa el almacenamiento."

  defp format_error({:persist_failed, _}),
    do: "No se pudo guardar el cambio. Revisa el almacenamiento."

  defp format_error(:profile_document_too_large),
    do: "La configuración supera el tamaño permitido."

  defp format_error(other), do: "Error: #{inspect(other)}"

  defp extract_token_from_conn(conn) do
    auth_header = Plug.Conn.get_req_header(conn, "authorization") |> List.first()

    token_from_header =
      case auth_header do
        "Bearer " <> token -> String.trim(token)
        "bearer " <> token -> String.trim(token)
        _ -> nil
      end

    if is_binary(token_from_header) and byte_size(token_from_header) > 0 do
      token_from_header
    else
      case conn.query_params do
        %Plug.Conn.Unfetched{} ->
          URI.decode_query(conn.query_string || "")["token"]

        map when is_map(map) ->
          map["token"]
      end
    end
  end

  defp api_regenerate_token(conn, handle) do
    case ChatOverlay.Profiles.regenerate_capability_token(handle) do
      {:ok, token, _profile} ->
        resp = %{
          "ok" => true,
          "token" => token,
          "overlay_url" => "/overlay/#{handle}?token=#{token}"
        }

        reply(conn, 200, "application/json", ChatOverlay.JSON.encode(resp))

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

  defp api_media_presign(conn) do
    case Plug.Conn.read_body(conn, length: 65_536, read_length: 8192, read_timeout: 4000) do
      {:ok, body, conn} ->
        case ChatOverlay.JSON.decode(body) do
          {:ok, %{"handle" => handle} = params} when is_binary(handle) ->
            with :ok <- Session.authorize(conn, handle) do
              case Config.profile(handle) do
                nil ->
                  reply(
                    conn,
                    404,
                    "application/json",
                    ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Perfil no encontrado"})
                  )

                profile ->
                  used = profile["storage_used_bytes"] || 0
                  quota = profile["storage_quota_bytes"] || 10_485_760

                  case ChatOverlay.Media.validate_upload_request(params, used, quota) do
                    {:ok, validated} ->
                      r2_config = %{
                        endpoint:
                          System.get_env("R2_ENDPOINT") ||
                            Application.get_env(
                              :chat_overlay,
                              :r2_endpoint,
                              "https://r2.example.com"
                            ),
                        bucket:
                          System.get_env("R2_BUCKET") ||
                            Application.get_env(:chat_overlay, :r2_bucket, "chat-overlay-media"),
                        access_key_id:
                          System.get_env("R2_ACCESS_KEY_ID") ||
                            Application.get_env(
                              :chat_overlay,
                              :r2_access_key_id,
                              "mock_access_key"
                            ),
                        secret_access_key:
                          System.get_env("R2_SECRET_ACCESS_KEY") ||
                            Application.get_env(
                              :chat_overlay,
                              :r2_secret_access_key,
                              "mock_secret_key"
                            ),
                        public_cdn_base:
                          System.get_env("R2_PUBLIC_CDN") ||
                            Application.get_env(
                              :chat_overlay,
                              :r2_public_cdn,
                              "https://media.chat-overlay.example.com"
                            )
                      }

                      case ChatOverlay.Media.generate_presigned_put(
                             Map.merge(r2_config, %{
                               key: validated.key,
                               content_type: validated.mime
                             })
                           ) do
                        {:ok, presigned} ->
                          resp = %{
                            "ok" => true,
                            "upload_url" => presigned.upload_url,
                            "public_url" => presigned.public_url,
                            "key" => presigned.key
                          }

                          reply(conn, 200, "application/json", ChatOverlay.JSON.encode(resp))

                        {:error, reason} ->
                          reply(
                            conn,
                            500,
                            "application/json",
                            ChatOverlay.JSON.encode(%{"ok" => false, "error" => inspect(reason)})
                          )
                      end

                    {:error, reason} ->
                      reply(
                        conn,
                        422,
                        "application/json",
                        ChatOverlay.JSON.encode(%{
                          "ok" => false,
                          "error" => format_media_error(reason)
                        })
                      )
                  end
              end
            else
              {:error, :unauthorized} ->
                reply(
                  conn,
                  401,
                  "application/json",
                  ChatOverlay.JSON.encode(%{"ok" => false, "error" => "No autorizado"})
                )

              {:error, :forbidden} ->
                reply(
                  conn,
                  403,
                  "application/json",
                  ChatOverlay.JSON.encode(%{
                    "ok" => false,
                    "error" => "Acceso no autorizado al perfil solicitado"
                  })
                )
            end

          _ ->
            reply(
              conn,
              400,
              "application/json",
              ChatOverlay.JSON.encode(%{
                "ok" => false,
                "error" => "Parámetros de subida inválidos"
              })
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

  defp api_update_media(conn, handle) do
    case Plug.Conn.read_body(conn, length: 65_536, read_length: 8192, read_timeout: 4000) do
      {:ok, body, conn} ->
        case ChatOverlay.JSON.decode(body) do
          {:ok, media_params} when is_map(media_params) ->
            case Config.profile(handle) do
              nil ->
                reply(
                  conn,
                  404,
                  "application/json",
                  ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Perfil no encontrado"})
                )

              _profile ->
                with :ok <- validate_media_params(media_params),
                     {:ok, updated} <- ChatOverlay.Profiles.update_media(handle, media_params) do
                  resp = %{"ok" => true, "media" => updated["media"]}
                  reply(conn, 200, "application/json", ChatOverlay.JSON.encode(resp))
                else
                  {:error, reason} ->
                    reply(
                      conn,
                      422,
                      "application/json",
                      ChatOverlay.JSON.encode(%{
                        "ok" => false,
                        "error" => format_media_error(reason)
                      })
                    )
                end
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

  defp validate_media_params(params) when is_map(params) do
    Enum.reduce_while(params, :ok, fn
      {"alert_sound", %{"url" => url, "source" => "external"}}, :ok
      when is_binary(url) and url != "" ->
        case ChatOverlay.Media.validate_external_url(url, :audio) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {"alert_image", %{"url" => url, "source" => "external"}}, :ok
      when is_binary(url) and url != "" ->
        case ChatOverlay.Media.validate_external_url(url, :image) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {key, _}, :ok when key in ["alert_sound", "alert_image"] ->
        {:cont, :ok}

      {other, _}, :ok ->
        {:halt, {:error, {:unknown_media_key, other}}}
    end)
  end

  defp format_media_error(:svg_prohibited_for_security),
    do: "Archivos SVG estrictamente prohibidos por seguridad (XSS en CEF de OBS)."

  defp format_media_error(:file_size_exceeded),
    do: "El archivo supera el tamaño máximo permitido (2 MB para audio, 512 KB para imagen)."

  defp format_media_error(:file_too_large),
    do: "El archivo supera el tamaño máximo permitido (2 MB para audio, 512 KB para imagen)."

  defp format_media_error(:destination_rejected),
    do: "Destino de red no permitido o no resuelve a una IP pública."

  defp format_media_error(:quota_exceeded),
    do: "Se ha superado la cuota de almacenamiento disponible para este perfil."

  defp format_media_error(:invalid_content_type),
    do: "Tipo de archivo o formato no permitido."

  defp format_media_error(:invalid_scheme_must_be_https),
    do: "La URL debe utilizar HTTPS seguro."

  defp format_media_error(:invalid_url),
    do: "La URL debe ser válida y utilizar HTTPS seguro."

  defp format_media_error(:unsupported_extension),
    do: "Extensión de archivo no soportada."

  defp format_media_error(:private_ip_forbidden),
    do: "Dirección IP privada o bucle local prohibido (SSRF)."

  defp format_media_error(:url_too_long),
    do: "La URL supera el límite máximo de 2048 caracteres."

  defp format_media_error(other), do: format_error(other)

  defp api_oauth_authorize(conn, provider) do
    params = URI.decode_query(conn.query_string || "")
    handle = params["handle"]
    profile = handle && Config.profile(handle)

    cond do
      is_nil(handle) or is_nil(profile) ->
        reply(
          conn,
          404,
          "application/json",
          ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Perfil no encontrado"})
        )

      provider not in ["twitch", "youtube"] ->
        reply(
          conn,
          400,
          "application/json",
          ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Proveedor no soportado"})
        )

      true ->
        token = extract_token_from_conn(conn)

        valid_capability_token? =
          is_binary(token) and byte_size(token) > 0 and
            is_binary(profile["capability_token_hash"]) and
            byte_size(profile["capability_token_hash"]) > 0 and
            ChatOverlay.Crypto.verify_token(token, profile["capability_token_hash"])

        session_auth = Session.authorize(conn, handle)
        session_valid? = session_auth == :ok

        linked_accounts = profile["linked_accounts"] || %{}
        has_linked? = linked_accounts[provider] && linked_accounts[provider]["user_id"] != nil

        demo_loopback? = Session.loopback?(conn) and Session.demo_profile?(handle)

        auth_proof =
          cond do
            session_valid? -> "session"
            valid_capability_token? -> "capability_token"
            has_linked? -> "login"
            demo_loopback? -> "demo"
            true -> nil
          end

        cond do
          session_auth == {:error, :forbidden} and not valid_capability_token? ->
            reply(
              conn,
              403,
              "application/json",
              ChatOverlay.JSON.encode(%{
                "ok" => false,
                "error" => "No autorizado para este perfil"
              })
            )

          is_nil(auth_proof) ->
            reply(
              conn,
              401,
              "application/json",
              ChatOverlay.JSON.encode(%{
                "ok" => false,
                "error" => "Autenticación o token de capacidad requerido"
              })
            )

          true ->
            redirect_uri = build_redirect_uri(conn, provider)

            case ChatOverlay.OAuth.authorize_url(provider, handle, redirect_uri,
                   auth_proof: auth_proof
                 ) do
              {:ok, auth_url} ->
                if params["redirect"] == "true" do
                  redirect(conn, auth_url)
                else
                  reply(
                    conn,
                    200,
                    "application/json",
                    ChatOverlay.JSON.encode(%{"ok" => true, "url" => auth_url})
                  )
                end

              {:error, {:unconfigured_client, prov}} ->
                reply(
                  conn,
                  400,
                  "application/json",
                  ChatOverlay.JSON.encode(%{
                    "ok" => false,
                    "error" =>
                      "El proveedor #{prov} no tiene client_id configurado (configure la variable de entorno correspondiente)."
                  })
                )

              {:error, _reason} ->
                reply(
                  conn,
                  500,
                  "application/json",
                  ChatOverlay.JSON.encode(%{
                    "ok" => false,
                    "error" => "Error al generar enlace OAuth"
                  })
                )
            end
        end
    end
  end

  defp oauth_callback(conn, provider) do
    params = URI.decode_query(conn.query_string || "")
    code = params["code"]
    state = params["state"]
    error = params["error"]

    cond do
      error != nil ->
        handle =
          case state && ChatOverlay.OAuth.verify_state(state) do
            {:ok, %{"handle" => h}} -> h
            _ -> ""
          end

        dest =
          if handle != "",
            do: "/?handle=#{handle}&error=#{URI.encode_www_form(error)}",
            else: "/?error=#{URI.encode_www_form(error)}"

        redirect(conn, dest)

      code == nil or state == nil ->
        redirect(conn, "/?error=missing_oauth_params")

      true ->
        redirect_uri = build_redirect_uri(conn, provider)

        case ChatOverlay.OAuth.handle_callback(provider, code, state, redirect_uri) do
          {:ok, result} ->
            profile = Config.profile(result.handle)

            if is_nil(profile) do
              redirect(conn, "/?error=profile_not_found")
            else
              existing_linked = (profile["linked_accounts"] || %{})[result.provider]
              existing_user_id = existing_linked && existing_linked["user_id"]

              source = Enum.find(profile["sources"] || [], &(&1["platform"] == result.provider))
              source_user_id = source && source["user_id"]
              source_channel = source && (source["channel"] || source["login"])

              auth_proof = result[:auth_proof]

              identity_mismatch? =
                cond do
                  existing_user_id ->
                    to_string(existing_user_id) != to_string(result.user_id)

                  is_map(source) and is_binary(source_user_id) and byte_size(source_user_id) > 0 and
                      source["mode"] != "demo" ->
                    to_string(source_user_id) != to_string(result.user_id)

                  auth_proof == "source_match" and is_map(source) and source["mode"] != "demo" and
                    is_binary(source_channel) and byte_size(source_channel) > 0 ->
                    String.downcase(to_string(result.username)) !=
                      String.downcase(to_string(source_channel))

                  true ->
                    false
                end

              ownership_verified? =
                cond do
                  existing_user_id ->
                    to_string(existing_user_id) == to_string(result.user_id)

                  auth_proof in ["session", "capability_token"] ->
                    true

                  auth_proof == "demo" ->
                    true

                  Session.loopback?(conn) and Session.demo_profile?(result.handle) ->
                    true

                  is_map(source) and is_binary(source_user_id) and byte_size(source_user_id) > 0 and
                      source["mode"] != "demo" ->
                    to_string(source_user_id) == to_string(result.user_id)

                  is_map(source) and source["mode"] != "demo" and is_binary(source_channel) and
                      byte_size(source_channel) > 0 ->
                    String.downcase(to_string(result.username)) ==
                      String.downcase(to_string(source_channel))

                  true ->
                    false
                end

              cond do
                identity_mismatch? ->
                  redirect(conn, "/?handle=#{result.handle}&error=identity_mismatch")

                not ownership_verified? ->
                  redirect(conn, "/?handle=#{result.handle}&error=unauthorized_profile_claim")

                true ->
                  account_data = %{
                    username: result.username,
                    user_id: result.user_id
                  }

                  case ChatOverlay.Profiles.link_account(
                         result.handle,
                         result.provider,
                         account_data,
                         result.tokens
                       ) do
                    {:ok, updated_profile} ->
                      linked_info = (updated_profile["linked_accounts"] || %{})[result.provider]
                      account_version = (linked_info && linked_info["account_version"]) || 1

                      session_data = %{
                        "handle" => result.handle,
                        "provider" => result.provider,
                        "user_id" => result.user_id,
                        "username" => result.username,
                        "account_version" => account_version
                      }

                      conn
                      |> Session.put_session(session_data)
                      |> redirect("/?handle=#{result.handle}&linked=#{result.provider}")

                    {:error, {err_type, _}}
                    when err_type in [:persist_failed, :directory_not_found] ->
                      redirect(conn, "/?handle=#{result.handle}&error=storage_unwritable")

                    {:error, _reason} ->
                      redirect(conn, "/?handle=#{result.handle}&error=link_failed")
                  end
              end
            end

          {:error, _reason} ->
            handle =
              case state && ChatOverlay.OAuth.verify_state(state) do
                {:ok, %{"handle" => h}} -> h
                _ -> ""
              end

            dest =
              if handle != "",
                do: "/?handle=#{handle}&error=oauth_failed",
                else: "/?error=oauth_failed"

            redirect(conn, dest)
        end
    end
  end

  defp api_auth_me(conn) do
    with {:ok, session} <- Session.fetch_session(conn),
         :ok <- Session.authorize(conn, session["handle"]) do
      resp = %{
        "ok" => true,
        "authenticated" => true,
        "handle" => session["handle"],
        "provider" => session["provider"],
        "user_id" => session["user_id"],
        "created_at" => session["created_at"],
        "expires_at" => session["expires_at"]
      }

      reply(conn, 200, "application/json", ChatOverlay.JSON.encode(resp))
    else
      _ ->
        conn =
          case Session.fetch_session(conn) do
            {:ok, _} -> Session.delete_session(conn)
            _ -> conn
          end

        resp = %{
          "ok" => true,
          "authenticated" => false
        }

        reply(conn, 200, "application/json", ChatOverlay.JSON.encode(resp))
    end
  end

  defp api_auth_logout(conn) do
    conn = Session.delete_session(conn)
    resp = %{"ok" => true, "message" => "Sesión cerrada correctamente"}
    reply(conn, 200, "application/json", ChatOverlay.JSON.encode(resp))
  end

  defp api_unlink_account(conn, handle, provider) do
    if Config.profile(handle) == nil do
      reply(
        conn,
        404,
        "application/json",
        ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Perfil no encontrado"})
      )
    else
      case ChatOverlay.Profiles.unlink_account(handle, provider) do
        {:ok, _} ->
          conn = Session.delete_session(conn)

          reply(
            conn,
            200,
            "application/json",
            ChatOverlay.JSON.encode(%{"ok" => true, "unlinked" => provider})
          )

        {:error, {err_type, _}} when err_type in [:persist_failed, :directory_not_found] ->
          reply(
            conn,
            500,
            "application/json",
            ChatOverlay.JSON.encode(%{
              "ok" => false,
              "error" => "Almacenamiento no escribible para persistir cambios"
            })
          )

        {:error, _reason} ->
          reply(
            conn,
            400,
            "application/json",
            ChatOverlay.JSON.encode(%{"ok" => false, "error" => "Error al desvincular la cuenta"})
          )
      end
    end
  end

  defp build_redirect_uri(conn, provider) do
    host = Plug.Conn.get_req_header(conn, "host") |> List.first() || "localhost:4100"
    proto = if String.starts_with?(host, ["localhost", "127.0.0.1"]), do: "http", else: "https"
    "#{proto}://#{host}/oauth/callback/#{provider}"
  end

  def redirect(conn, location) do
    safe_location = Plug.HTML.html_escape(location)

    conn
    |> Plug.Conn.merge_resp_headers(HTTP.headers("text/html; charset=utf-8"))
    |> Plug.Conn.put_resp_header("location", location)
    |> Plug.Conn.send_resp(
      302,
      "<html><body>Redirecting to <a href=\"#{safe_location}\">#{safe_location}</a></body></html>"
    )
  end
end
