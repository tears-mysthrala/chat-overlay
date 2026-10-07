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
              if Process.whereis(ChatOverlay.SSERegistry) do
                flush_stale_revocations()
                reg_meta = if is_overlay, do: {:overlay, token}, else: :reader
                Registry.register(ChatOverlay.SSERegistry, handle, reg_meta)
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
                {preview_cursor, _} = Store.preview_since(Store.name(handle), nil)
                Process.put({__MODULE__, :preview_cursor}, preview_cursor)

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
              if Process.whereis(ChatOverlay.SSERegistry) do
                Registry.unregister(ChatOverlay.SSERegistry, handle)
              end

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
  Actively disconnects SSE viewers for a profile handle.
  - `:token_revoked`: disconnects overlay viewers whose capability token changed (SEC-09).
  - `:profile_deleted`: disconnects all viewers (overlay and reader) when profile is deleted.
  """
  def disconnect_viewers(handle, reason \\ :token_revoked)

  def disconnect_viewers(handle, reason) when is_binary(handle) do
    if Process.whereis(ChatOverlay.SSERegistry) do
      Registry.dispatch(ChatOverlay.SSERegistry, handle, fn entries ->
        for {pid, reg_meta} <- entries do
          case {reason, reg_meta} do
            {:token_revoked, {:overlay, _token}} ->
              send(pid, {:capability_token_revoked, handle})

            {:token_revoked, _raw_token} when not is_atom(reg_meta) ->
              send(pid, {:capability_token_revoked, handle})

            {:profile_deleted, {:overlay, _token}} ->
              send(pid, {:capability_token_revoked, handle})

            {:profile_deleted, _raw_token} when not is_atom(reg_meta) ->
              send(pid, {:capability_token_revoked, handle})

            {:profile_deleted, :reader} ->
              send(pid, {:profile_deleted, handle})

            _ ->
              :ok
          end
        end
      end)
    else
      :ok
    end
  end

  def disconnect_viewers(_, _), do: :ok

  defp flush_stale_revocations do
    receive do
      {:capability_token_revoked, _} -> flush_stale_revocations()
      :capability_token_revoked -> flush_stale_revocations()
      {:profile_deleted, _} -> flush_stale_revocations()
    after
      0 -> :ok
    end
  end

  defp poll(conn, handle, cursor, is_overlay, token, last) do
    result =
      try do
        Store.read(Store.name(handle), cursor)
      catch
        :exit, _ ->
          if is_nil(Config.profile(handle)) do
            if is_overlay, do: :capability_revoked, else: :profile_deleted
          else
            %{cursor: cursor, events: []}
          end
      end

    cond do
      conn.private[:custodian_reader] == true and
          ChatOverlay.Session.authorize(conn, handle) != :ok ->
        _ = Plug.Conn.chunk(conn, "event: error\ndata: {\"error\":\"unauthorized\"}\n\n")
        conn

      result == :capability_revoked ->
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

      result == :profile_deleted ->
        _ =
          Plug.Conn.chunk(
            conn,
            "event: error\ndata: " <>
              ChatOverlay.JSON.encode(%{
                "error" => "not_found",
                "message" => "Profile deleted"
              }) <>
              "\n\n"
          )

        conn

      true ->
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

        response =
          case response do
            {:ok, conn} -> preview_chunk(conn, handle, is_overlay, token)
            error -> error
          end

        case response do
          {:ok, conn} ->
            receive do
              {:tcp_closed, _} ->
                conn

              {:tcp_error, _, _} ->
                conn

              {:ssl_closed, _} ->
                conn

              {:ssl_error, _, _} ->
                conn

              {:capability_token_revoked, ^handle} ->
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

              {:capability_token_revoked, _other_handle} ->
                # Discard stale revocation from previous request on keep-alive connection
                poll(
                  conn,
                  handle,
                  result.cursor,
                  is_overlay,
                  token,
                  if(data, do: now, else: last)
                )

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

              {:profile_deleted, ^handle} ->
                _ =
                  Plug.Conn.chunk(
                    conn,
                    "event: error\ndata: " <>
                      ChatOverlay.JSON.encode(%{
                        "error" => "not_found",
                        "message" => "Profile deleted"
                      }) <>
                      "\n\n"
                  )

                conn

              {:profile_deleted, _other_handle} ->
                poll(
                  conn,
                  handle,
                  result.cursor,
                  is_overlay,
                  token,
                  if(data, do: now, else: last)
                )
            after
              50 ->
                poll(
                  conn,
                  handle,
                  result.cursor,
                  is_overlay,
                  token,
                  if(data, do: now, else: last)
                )
            end

          {:error, _} ->
            conn
        end
    end
  end

  defp preview_chunk(conn, handle, true, token) do
    {cursor, event} =
      Store.preview_since(Store.name(handle), Process.get({__MODULE__, :preview_cursor}))

    Process.put({__MODULE__, :preview_cursor}, cursor)

    with event when is_map(event) <- event,
         {:ok, _} <- ChatOverlay.Profiles.verify_capability_token(handle, token),
         profile when is_map(profile) <- Config.profile(handle),
         {:ok, payload} <-
           ChatOverlay.MediaPreview.payload(profile, ChatOverlay.Profiles.media_objects()),
         true <- Map.drop(event, ["id", "expires_at"]) == payload do
      Plug.Conn.chunk(conn, [
        "event: media_preview\ndata: ",
        ChatOverlay.JSON.encode(event),
        "\n\n"
      ])
    else
      _ -> {:ok, conn}
    end
  end

  defp preview_chunk(conn, _, _, _), do: {:ok, conn}

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
