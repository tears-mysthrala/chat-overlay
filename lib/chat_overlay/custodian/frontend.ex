defmodule ChatOverlay.Custodian.Frontend do
  @moduledoc "Public HTTP role. No local profiles, sessions, persistence or upstream credentials."
  @behaviour Plug
  alias ChatOverlay.Custodian.Client
  alias ChatOverlay.{HTTP, JSON, Transport}
  def init(options), do: options

  def call(conn, _) do
    case {conn.method, conn.path_info} do
      {"GET", ["events", handle]} ->
        stream(conn, handle)

      {"PUT", ["api", "media", "upload", handle]} ->
        upload(conn, handle)

      {method, []} when method in ["GET", "HEAD"] ->
        asset(conn, "index.html")

      {method, ["assets", file]}
      when method in ["GET", "HEAD"] and file in ["app.js", "app.css"] ->
        asset(conn, file)

      {method, ["favicon.ico"]} when method in ["GET", "HEAD"] ->
        reply(conn, 204, "image/x-icon", "")

      {method, ["health", "live"]} when method in ["GET", "HEAD"] ->
        reply(conn, 200, "text/plain", "ok")

      {method, ["health", "ready"]} when method in ["GET", "HEAD"] ->
        case Client.call(request("health.ready", %{})) do
          {:ok, %{"kind" => "readiness", "ready" => true}} ->
            reply(conn, 200, "text/plain", "ready")

          _ ->
            unavailable(conn)
        end

      _ ->
        operation(conn)
    end
  end

  defp upload(conn, handle) do
    args = %{
      "handle" => handle,
      "key" => List.first(Plug.Conn.get_req_header(conn, "x-upload-key")),
      "upload_token" => List.first(Plug.Conn.get_req_header(conn, "x-upload-token")),
      "mime" => List.first(Plug.Conn.get_req_header(conn, "content-type"))
    }

    with true <- valid_origin?(conn),
         {:ok, args} <- context(conn, "media.upload_authorize", args),
         {:ok, %{"kind" => "upload_permit", "size" => size}} <-
           Client.call(request("media.upload_authorize", args)),
         {:ok, bytes, conn} <- Plug.Conn.read_body(conn, length: size, read_timeout: 4000),
         true <- byte_size(bytes) == size,
         {:ok, result} <- Client.upload(request("media.upload", args), bytes) do
      respond(conn, result)
    else
      _ -> reply(conn, 422, "application/json", "{\"ok\":false,\"error\":\"Subida rechazada\"}")
    end
  end

  defp stream(conn, handle) do
    query = URI.decode_query(conn.query_string)

    args =
      %{
        "handle" => handle,
        "view" => if(query["view"] == "overlay", do: "overlay", else: "reader")
      }
      |> optional("capability", capability(conn, query))
      |> optional("cursor", List.first(Plug.Conn.get_req_header(conn, "last-event-id")))

    {:ok, args} = context(conn, "events.subscribe", args)
    ChatOverlay.Custodian.StreamRelay.call(conn, request("events.subscribe", args))
  end

  defp operation(conn) do
    with {:ok, op, args, body?} <- operation_for(conn),
         true <- conn.method not in ["POST", "PUT", "DELETE"] or valid_origin?(conn),
         true <- op not in ["oauth.begin", "oauth.complete"] or Transport.oauth_allowed?(conn),
         {:ok, args, conn} <- document(conn, args, body?),
         args = domain_arguments(op, args),
         {:ok, args} <- context(conn, op, args),
         {:ok, result} <- Client.call(request(op, args)) do
      respond(conn, result)
    else
      :not_found ->
        reply(conn, 404, "text/plain", "Not found")

      {:error, :invalid_body} ->
        reply(conn, 400, "application/json", "{\"ok\":false,\"error\":\"Invalid body\"}")

      {:error, :content_type} ->
        reply(conn, 415, "application/json", "{\"ok\":false}")

      false ->
        reply(conn, 403, "application/json", "{\"ok\":false}")

      _ ->
        unavailable(conn)
    end
  end

  defp operation_for(conn) do
    case {conn.method, conn.path_info} do
      {"GET", ["media", "local" | parts]} ->
        {:ok, "media.read", %{"key" => Enum.join(parts, "/")}, false}

      {"GET", [view, h]} when view in ["reader", "overlay"] ->
        query = URI.decode_query(conn.query_string)
        args = %{"handle" => h, "view" => view} |> optional("capability", capability(conn, query))
        {:ok, "view.authorize", args, false}

      {"GET", ["api", "auth", "me"]} ->
        {:ok, "session.get", %{}, false}

      {"GET", ["api", "session"]} ->
        {:ok, "session.get", %{}, false}

      {"POST", ["api", "auth", "logout"]} ->
        {:ok, "session.logout", %{}, false}

      {"GET", ["api", "profiles"]} ->
        {:ok, "profiles.list", %{}, false}

      {"POST", ["api", "profiles"]} ->
        {:ok, "profiles.save", %{}, true}

      {"POST", ["api", "resolve"]} ->
        {:ok, "profiles.resolve", %{}, true}

      {"DELETE", ["api", "profiles", h]} ->
        {:ok, "profiles.delete", %{"handle" => h}, false}

      {"POST", ["api", "profiles", h, "sync-youtube"]} ->
        {:ok, "profiles.sync_youtube", %{"handle" => h}, false}

      {"POST", ["api", "profiles", h, "token", "regenerate"]} ->
        {:ok, "profiles.rotate_capability", %{"handle" => h}, false}

      {"POST", ["api", "profiles", h, "unlink", p]} ->
        {:ok, "profiles.unlink", %{"handle" => h, "provider" => p}, false}

      {"POST", ["api", "profiles", h, "media"]} ->
        {:ok, "media.save", %{"handle" => h}, true}

      {"POST", ["api", "profiles", h, "media", "preview"]} ->
        {:ok, "media.preview", %{"handle" => h}, true}

      {"POST", ["api", "media", "presign"]} ->
        {:ok, "media.reserve", %{}, true}

      {"POST", ["api", "media", "validate"]} ->
        {:ok, "media.validate", %{}, true}

      {"GET", ["api", "oauth", "authorize", p]} ->
        query = URI.decode_query(conn.query_string)
        args = %{"provider" => p, "handle" => query["handle"]}
        {:ok, "oauth.begin", optional(args, "capability", query["token"]), false}

      {"GET", ["oauth", "callback", p]} ->
        args = Map.take(URI.decode_query(conn.query_string), ["state", "code", "error"])
        {:ok, "oauth.complete", Map.put(args, "provider", p), false}

      _ ->
        :not_found
    end
  end

  defp document(conn, args, false), do: {:ok, args, conn}

  defp document(conn, args, true) do
    if Enum.any?(
         Plug.Conn.get_req_header(conn, "content-type"),
         &(String.downcase(String.trim(hd(String.split(&1, ";")))) == "application/json")
       ) do
      with {:ok, bytes, conn} <- Plug.Conn.read_body(conn, length: 65_536, read_timeout: 4000),
           {:ok, doc} when is_map(doc) <- JSON.decode(bytes) do
        {:ok, Map.put(args, "document", doc), conn}
      else
        _ -> {:error, :invalid_body}
      end
    else
      {:error, :content_type}
    end
  end

  defp domain_arguments("profiles.resolve", %{"document" => doc}),
    do: %{"target" => doc["target"]} |> optional("platform", doc["platform"])

  defp domain_arguments(_, args), do: args

  defp context(conn, op, args) do
    conn = Plug.Conn.fetch_cookies(conn)

    args =
      args
      |> optional("session", conn.cookies[ChatOverlay.Session.cookie_name()])
      |> optional("origin", List.first(Plug.Conn.get_req_header(conn, "origin")))
      |> Map.put("requester", Transport.requester(conn) |> :inet.ntoa() |> to_string())

    if op == "oauth.complete" and is_binary(args["state"]) do
      name = ChatOverlay.OAuthFlow.cookie_name(args["state"], true)
      {:ok, optional(args, "browser", conn.cookies[name])}
    else
      {:ok, args}
    end
  end

  defp respond(conn, %{"kind" => "media", "status" => 200, "mime" => mime, "bytes" => bytes}),
    do: reply(conn, 200, mime, Base.decode64!(bytes))

  defp respond(conn, %{"kind" => "media", "status" => 404}),
    do: reply(conn, 404, "text/plain", "Not found")

  defp respond(conn, %{"kind" => "view", "status" => 200, "demo" => demo}) do
    body = File.read!(Application.app_dir(:chat_overlay, "priv/static/chat.html"))

    reply(
      conn,
      200,
      "text/html; charset=utf-8",
      String.replace(body, "__DEMO__", to_string(demo))
    )
  end

  defp respond(conn, %{"kind" => "view", "status" => status}),
    do: reply(conn, status, "text/plain", "View unavailable")

  defp respond(conn, %{"kind" => "json", "status" => status, "data" => data, "cookies" => cookies}),
       do: conn |> put_cookies(cookies) |> reply(status, "application/json", JSON.encode(data))

  defp respond(conn, %{
         "kind" => "redirect",
         "status" => status,
         "location" => location,
         "cookies" => cookies
       }),
       do:
         conn
         |> put_cookies(cookies)
         |> Plug.Conn.put_resp_header("location", location)
         |> reply(status, "text/plain", "Redirecting")

  defp put_cookies(conn, cookies) do
    Enum.reduce(cookies, conn, fn cookie, conn ->
      options = [secure: true, http_only: true, same_site: "Lax", path: "/"]

      options =
        if cookie["max_age"], do: Keyword.put(options, :max_age, cookie["max_age"]), else: options

      Plug.Conn.put_resp_cookie(conn, cookie["name"], cookie["value"], options)
    end)
  end

  defp valid_origin?(conn),
    do:
      Plug.Conn.get_req_header(conn, "origin") == [
        Application.get_env(:chat_overlay, :oauth_origin)
      ]

  defp request(op, args), do: %{"version" => 1, "operation" => op, "arguments" => args}

  defp capability(conn, query) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      ["bearer " <> token] -> String.trim(token)
      _ -> query["token"]
    end
  end

  defp optional(args, _, nil), do: args
  defp optional(args, key, value), do: Map.put(args, key, value)
  defp unavailable(conn), do: reply(conn, 503, "text/plain", "unavailable")

  defp reply(conn, status, type, body),
    do:
      conn
      |> Plug.Conn.merge_resp_headers(HTTP.headers(type))
      |> Plug.Conn.send_resp(status, body)

  defp asset(conn, name) do
    type =
      case Path.extname(name) do
        ".html" -> "text/html; charset=utf-8"
        ".css" -> "text/css; charset=utf-8"
        ".js" -> "text/javascript; charset=utf-8"
      end

    reply(conn, 200, type, File.read!(Application.app_dir(:chat_overlay, "priv/static/" <> name)))
  end
end
