defmodule ChatOverlay.Custodian.Operations do
  @moduledoc "Finite domain operations. Transport identity never grants profile authorization."
  alias ChatOverlay.Custodian.{BodyAdapter, Protocol, Result}

  @routes %{
    "session.get" => {"GET", ["api", "auth", "me"]},
    "session.logout" => {"POST", ["api", "auth", "logout"]},
    "profiles.list" => {"GET", ["api", "profiles"]},
    "profiles.save" => {"POST", ["api", "profiles"]},
    "profiles.resolve" => {"POST", ["api", "resolve"]},
    "media.reserve" => {"POST", ["api", "media", "presign"]},
    "media.validate" => {"POST", ["api", "media", "validate"]},
    "health.ready" => {"GET", ["health", "ready"]}
  }

  def execute(request) do
    with :ok <- Protocol.validate(request),
         {:ok, result} <- execute_valid(request),
         :ok <- Result.validate(result),
         do: {:ok, result}
  end

  defp execute_valid(%{"operation" => "view.authorize", "arguments" => args} = request) do
    with {:ok, conn} <- connection(request) do
      status = view_status(conn, args)
      profile = ChatOverlay.Config.profile(args["handle"])
      demo = status == 200 and Enum.any?(profile["sources"] || [], &(&1["mode"] == "demo"))
      {:ok, %{"version" => 1, "kind" => "view", "status" => status, "demo" => demo}}
    end
  end

  defp execute_valid(%{"operation" => "media.upload_authorize", "arguments" => args} = request) do
    with {:ok, conn} <- connection(request) do
      ChatOverlay.RequestScope.request(fn ->
        case ChatOverlay.Web.custodian_upload_object(upload_headers(conn, args), args["handle"]) do
          {:ok, object} ->
            {:ok, %{"version" => 1, "kind" => "upload_permit", "size" => object["size"]}}

          _ ->
            {:error, :upload_rejected}
        end
      end)
    end
  end

  defp execute_valid(%{"operation" => "media.read"} = request) do
    with {:ok, conn} <- connection(request), response <- ChatOverlay.Web.call(conn, []) do
      if response.status == 200 do
        mime = List.first(Plug.Conn.get_resp_header(response, "content-type"))
        bytes = response.resp_body

        result = %{
          "version" => 1,
          "kind" => "media",
          "status" => 200,
          "mime" => mime,
          "size" => byte_size(bytes),
          "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
          "bytes" => Base.encode64(bytes)
        }

        with :ok <- Result.validate(result), do: {:ok, result}
      else
        {:ok, %{"version" => 1, "kind" => "media", "status" => 404}}
      end
    end
  end

  defp execute_valid(request) do
    with :ok <- Protocol.validate(request),
         {:ok, conn} <- connection(request),
         response <- dispatch_authorized(conn, request),
         {:ok, result} <- result(response),
         :ok <- Result.validate(result) do
      {:ok, result}
    end
  end

  defp dispatch_authorized(conn, %{"operation" => op, "arguments" => args}) do
    authorizer =
      cond do
        op == "profiles.save" ->
          fn -> ChatOverlay.Session.authorize_profile_creation(conn, args["document"]) end

        op in [
          "profiles.delete",
          "profiles.sync_youtube",
          "profiles.rotate_capability",
          "profiles.unlink",
          "media.reserve",
          "media.validate",
          "media.save",
          "media.preview"
        ] ->
          handle = args["handle"] || (args["document"] || %{})["handle"]
          fn -> ChatOverlay.Session.authorize(conn, handle) end

        true ->
          fn -> :ok end
      end

    ChatOverlay.RequestScope.with_authorizer(authorizer, fn -> ChatOverlay.Web.call(conn, []) end)
  end

  def upload(%{"operation" => "media.upload", "arguments" => args} = request, bytes)
      when is_binary(bytes) and byte_size(bytes) <= 2_097_152 do
    with :ok <- Protocol.validate(request), {:ok, conn} <- connection(request) do
      conn = %{upload_headers(conn, args) | adapter: {BodyAdapter, bytes}}

      with response <- ChatOverlay.Web.call(conn, []),
           {:ok, result} <- result(response),
           :ok <- Result.validate(result),
           do: {:ok, result}
    end
  end

  def upload(_, _), do: {:error, :upload_rejected}

  defp upload_headers(conn, args),
    do:
      conn
      |> Plug.Conn.put_req_header("content-type", args["mime"])
      |> Plug.Conn.put_req_header("x-upload-key", args["key"])
      |> Plug.Conn.put_req_header("x-upload-token", args["upload_token"])

  def authorize_stream(args) do
    request = %{
      "version" => 1,
      "operation" => "view.authorize",
      "arguments" => Map.drop(args, ["cursor"])
    }

    with :ok <- Protocol.validate(request), {:ok, conn} <- connection(request) do
      view_status(conn, args)
    else
      _ -> 401
    end
  end

  defp view_status(conn, args) do
    ChatOverlay.RequestScope.request(fn ->
      cond do
        is_nil(ChatOverlay.Config.profile(args["handle"])) ->
          404

        args["view"] == "overlay" ->
          if match?(
               {:ok, _},
               ChatOverlay.Profiles.verify_capability_token(args["handle"], args["capability"])
             ), do: 200, else: 401

        true ->
          case ChatOverlay.Session.authorize(conn, args["handle"]) do
            :ok -> 200
            {:error, :forbidden} -> 403
            _ -> 401
          end
      end
    end)
  end

  defp connection(%{"operation" => op, "arguments" => args}) do
    with {:ok, {method, path}} <- route(op, args),
         origin when is_binary(origin) <- Application.get_env(:chat_overlay, :oauth_origin),
         %URI{scheme: "https", host: host} <- URI.parse(origin),
         true <- method not in ["POST", "PUT", "DELETE"] or args["origin"] == origin,
         {:ok, peer} <- peer(args["requester"]) do
      body = body(op, args)
      query = query(op, args)
      headers = [{"content-type", "application/json"}]
      headers = if args["origin"], do: [{"origin", args["origin"]} | headers], else: headers

      cookies =
        if args["session"], do: [{ChatOverlay.Session.cookie_name(), args["session"]}], else: []

      cookies = browser_cookie(op, args) ++ cookies

      conn = %Plug.Conn{
        adapter: {BodyAdapter, body},
        method: method,
        path_info: path,
        request_path: "/" <> Enum.join(path, "/"),
        query_string: URI.encode_query(query),
        host: host,
        port: 443,
        scheme: :https,
        remote_ip: peer,
        req_headers: headers,
        req_cookies: Map.new(cookies),
        cookies: Map.new(cookies)
      }

      {:ok, conn}
    else
      _ -> {:error, :invalid_context}
    end
  end

  defp peer(nil), do: {:ok, {192, 0, 2, 1}}

  defp peer(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, {127, _, _, _}} -> {:error, :invalid_context}
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> {:error, :invalid_context}
      {:ok, address} -> {:ok, address}
      _ -> {:error, :invalid_context}
    end
  end

  defp route("profiles.delete", a), do: {:ok, {"DELETE", ["api", "profiles", a["handle"]]}}
  defp route("view.authorize", a), do: {:ok, {"GET", [a["view"], a["handle"]]}}

  defp route("media.read", a),
    do: {:ok, {"GET", ["media", "local" | String.split(a["key"], "/")]}}

  defp route(op, a) when op in ["media.upload", "media.upload_authorize"],
    do: {:ok, {"PUT", ["api", "media", "upload", a["handle"]]}}

  defp route("profiles.sync_youtube", a), do: profile_route(a, ["sync-youtube"])
  defp route("profiles.rotate_capability", a), do: profile_route(a, ["token", "regenerate"])
  defp route("profiles.unlink", a), do: profile_route(a, ["unlink", a["provider"]])
  defp route("media.save", a), do: profile_route(a, ["media"])
  defp route("media.preview", a), do: profile_route(a, ["media", "preview"])
  defp route("oauth.begin", a), do: {:ok, {"GET", ["api", "oauth", "authorize", a["provider"]]}}
  defp route("oauth.complete", a), do: {:ok, {"GET", ["oauth", "callback", a["provider"]]}}
  defp route(op, _), do: Map.fetch(@routes, op)
  defp profile_route(a, tail), do: {:ok, {"POST", ["api", "profiles", a["handle"] | tail]}}

  defp body("profiles.resolve", args),
    do: ChatOverlay.JSON.encode(Map.take(args, ["target", "platform"]))

  defp body(_, args), do: ChatOverlay.JSON.encode(args["document"] || %{})
  defp query("oauth.begin", args), do: rename_capability(Map.take(args, ["handle", "capability"]))
  defp query("oauth.complete", args), do: Map.take(args, ["state", "code", "error"])
  defp query(_, _), do: %{}

  defp rename_capability(%{"capability" => token} = args),
    do: Map.put(Map.delete(args, "capability"), "token", token)

  defp rename_capability(args), do: args

  defp browser_cookie("oauth.complete", args),
    do: [{ChatOverlay.OAuthFlow.cookie_name(args["state"], true), args["browser"]}]

  defp browser_cookie(_, _), do: []

  defp result(conn) do
    type = List.first(Plug.Conn.get_resp_header(conn, "content-type"))
    location = List.first(Plug.Conn.get_resp_header(conn, "location"))

    cond do
      conn.status in [301, 302, 303] and is_binary(location) ->
        {:ok,
         %{
           "version" => 1,
           "kind" => "redirect",
           "status" => conn.status,
           "location" => location,
           "cookies" => cookies(conn)
         }}

      is_binary(type) and String.starts_with?(type, "application/json") ->
        with {:ok, data} <- ChatOverlay.JSON.decode(conn.resp_body),
             data = public_response(data),
             true <- secret_free?(data) do
          {:ok,
           %{
             "version" => 1,
             "kind" => "json",
             "status" => conn.status,
             "data" => data,
             "cookies" => cookies(conn)
           }}
        else
          _ -> {:error, :response_rejected}
        end

      type == "text/plain" and conn.resp_body in ["ready", "unavailable"] ->
        {:ok, %{"version" => 1, "kind" => "readiness", "ready" => conn.status == 200}}

      true ->
        {:error, :response_rejected}
    end
  end

  defp public_response(%{"profile" => %{"handle" => _} = profile} = data),
    do: Map.put(data, "profile", ChatOverlay.Profiles.public_summary(profile))

  defp public_response(data), do: data

  defp cookies(conn) do
    Enum.map(conn.resp_cookies, fn {name, value} ->
      %{
        "name" => name,
        "value" => value[:value] || "",
        "max_age" => value[:max_age],
        "secure" => true,
        "http_only" => true,
        "same_site" => "Lax",
        "path" => "/"
      }
    end)
  end

  defp secret_free?(map) when is_map(map),
    do:
      Enum.all?(map, fn {key, value} ->
        key not in [
          "access_token",
          "refresh_token",
          "encrypted_tokens",
          "client_secret",
          "encryption_key",
          "db_password"
        ] and secret_free?(value)
      end)

  defp secret_free?(list) when is_list(list), do: Enum.all?(list, &secret_free?/1)
  defp secret_free?(_), do: true
end
