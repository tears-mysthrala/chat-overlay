defmodule ChatOverlay.Stream do
  @moduledoc "Pull-based SSE; slow readers reset from bounded replay."
  alias ChatOverlay.{Admission, Config, HTTP, Store}

  def call(conn, handle) do
    params = URI.decode_query(conn.query_string || "")
    is_overlay = params["view"] == "overlay"
    token = params["token"]

    cond do
      is_overlay and
          match?(
            {:error, :unauthorized},
            ChatOverlay.Profiles.verify_capability_token(handle, token)
          ) ->
        ChatOverlay.Web.reply(conn, 401, "text/plain", "Unauthorized: Capability Token Invalid")

      match?({:error, :not_found}, Config.profile(handle)) or is_nil(Config.profile(handle)) ->
        ChatOverlay.Web.reply(conn, 404, "text/plain", "Not found")

      true ->
        case Admission.acquire(handle) do
          :ok ->
            try do
              if is_overlay and Process.whereis(ChatOverlay.SSERegistry) do
                Registry.register(ChatOverlay.SSERegistry, handle, token)
              end

              if is_overlay and
                   match?(
                     {:error, :unauthorized},
                     ChatOverlay.Profiles.verify_capability_token(handle, token)
                   ) do
                ChatOverlay.Web.reply(
                  conn,
                  401,
                  "text/plain",
                  "Unauthorized: Capability Token Invalid"
                )
              else
                conn =
                  conn
                  |> Plug.Conn.merge_resp_headers(
                    HTTP.headers("text/event-stream; charset=utf-8")
                  )
                  |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
                  |> Plug.Conn.send_chunked(200)

                {:ok, conn} = Plug.Conn.chunk(conn, "retry: 2000\n\n")
                cursor = List.first(Plug.Conn.get_req_header(conn, "last-event-id"))
                poll(conn, handle, cursor, is_overlay, token, System.monotonic_time(:millisecond))
              end
            after
              Admission.release()
            end

          {:error, :capacity} ->
            ChatOverlay.Web.reply(conn, 503, "text/plain", "Unavailable")

          _ ->
            ChatOverlay.Web.reply(conn, 404, "text/plain", "Not found")
        end
    end
  end

  @doc """
  Actively disconnects all open SSE overlay viewers for a profile handle.
  Used when capability tokens are regenerated or profiles are deleted (SEC-09).
  """
  def disconnect_viewers(handle) when is_binary(handle) do
    if Process.whereis(ChatOverlay.SSERegistry) do
      Registry.dispatch(ChatOverlay.SSERegistry, handle, fn entries ->
        for {pid, _token} <- entries do
          send(pid, :capability_token_revoked)
        end
      end)
    else
      :ok
    end
  end

  def disconnect_viewers(_), do: :ok

  defp poll(conn, handle, cursor, is_overlay, token, last) do
    result = Store.read(Store.name(handle), cursor)
    now = System.monotonic_time(:millisecond)
    current_platforms = platforms_for(handle, is_overlay)

    data =
      cond do
        result.events != [] ->
          [
            "id: ",
            result.cursor,
            "\nevent: batch\ndata: ",
            ChatOverlay.JSON.encode(%{
              "events" => filter_events(result.events, current_platforms)
            }),
            "\n\n"
          ]

        now - last >= 15_000 ->
          ": heartbeat\n\n"

        true ->
          nil
      end

    response = if data, do: Plug.Conn.chunk(conn, data), else: {:ok, conn}

    case response do
      {:ok, conn} ->
        receive do
          {:tcp_closed, _} ->
            conn

          {:tcp_error, _, _} ->
            conn

          :capability_token_revoked ->
            _ =
              Plug.Conn.chunk(
                conn,
                "event: error\ndata: " <>
                  ChatOverlay.JSON.encode(%{
                    "error" => "unauthorized",
                    "message" => "Capability token revoked"
                  }) <>
                  "\n\n"
              )

            conn
        after
          50 ->
            poll(conn, handle, result.cursor, is_overlay, token, if(data, do: now, else: last))
        end

      {:error, _} ->
        conn
    end
  end

  def filter_events(events, platforms) do
    Enum.flat_map(events, fn
      %{"event" => "snapshot", "payload" => p} = e ->
        p = %{
          p
          | "messages" => Enum.filter(p["messages"], &(&1["platform"] in platforms)),
            "source_states" => Enum.filter(p["source_states"], &(&1["platform"] in platforms))
        }

        [%{e | "payload" => p}]

      %{"event" => "reset"} = e ->
        [e]

      e ->
        if e["platform"] in platforms, do: [Map.delete(e, "local_sequence")], else: []
    end)
  end

  defp platforms_for(handle, is_overlay) do
    case Config.profile(handle) do
      nil ->
        []

      p ->
        all = Enum.map(p["sources"] || [], & &1["platform"])
        if is_overlay, do: p["overlay_platforms"] || all, else: all
    end
  end
end
