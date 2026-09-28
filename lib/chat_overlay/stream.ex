defmodule ChatOverlay.Stream do
  @moduledoc "Pull-based SSE; slow readers reset from bounded replay."
  alias ChatOverlay.{Admission, Config, HTTP, Store}

  def call(conn, handle) do
    case Admission.acquire(handle) do
      :ok ->
        try do
          conn =
            conn
            |> Plug.Conn.merge_resp_headers(HTTP.headers("text/event-stream; charset=utf-8"))
            |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
            |> Plug.Conn.send_chunked(200)

          {:ok, conn} = Plug.Conn.chunk(conn, "retry: 2000\n\n")
          cursor = List.first(Plug.Conn.get_req_header(conn, "last-event-id"))
          is_overlay = conn.query_string == "view=overlay"
          poll(conn, handle, cursor, is_overlay, System.monotonic_time(:millisecond))
        after
          Admission.release()
        end

      {:error, :capacity} ->
        ChatOverlay.Web.reply(conn, 503, "text/plain", "Unavailable")

      _ ->
        ChatOverlay.Web.reply(conn, 404, "text/plain", "Not found")
    end
  end

  defp poll(conn, handle, cursor, is_overlay, last) do
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
          {:tcp_closed, _} -> conn
          {:tcp_error, _, _} -> conn
        after
          50 -> poll(conn, handle, result.cursor, is_overlay, if(data, do: now, else: last))
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
