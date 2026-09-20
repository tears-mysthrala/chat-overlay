defmodule ChatOverlay.Store do
  @moduledoc "Single-owner overlay state. Bounded replay, dedup and deletion barriers; no disk."
  use GenServer
  alias ChatOverlay.Event
  @history_ms 1_800_000
  @ring 512
  @seen 4096
  @barriers 4096
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])
  def name(handle), do: {:via, Registry, {ChatOverlay.Registry, {:store, handle}}}

  def child_spec(profile),
    do: %{
      id: {:store, profile["handle"]},
      start:
        {__MODULE__, :start_link, [[name: name(profile["handle"]), sources: profile["sources"]]]}
    }

  def ingest(server, event), do: GenServer.call(server, {:ingest, event})
  def read(server, cursor \\ nil), do: GenServer.call(server, {:read, cursor})

  def init(opts) do
    Process.send_after(self(), :expire, 1000)

    {:ok,
     %{
       epoch: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
       sequence: 0,
       messages: [],
       states: %{},
       ring: [],
       seen: %{},
       seen_order: :queue.new(),
       barriers: %{},
       sources: MapSet.new(Enum.map(opts[:sources] || [], &{&1["platform"], &1["channel"]}))
     }}
  end

  def format_status(status), do: Map.put(status, :state, :redacted_overlay_state)

  def handle_call({:ingest, e}, _, s) do
    if Event.valid?(e) and MapSet.member?(s.sources, source(e)) do
      key = {source(e), e["emission_session"], e["event"], e["upstream_id"]}

      if Map.has_key?(s.seen, key) do
        {:reply, :duplicate, s}
      else
        case apply_event(s, e) do
          {:ok, next} -> {:reply, :ok, next |> remember(key) |> append(e)}
          {:error, reason} -> {:reply, {:error, reason}, s}
        end
      end
    else
      {:reply, {:error, :invalid_event}, s}
    end
  end

  def handle_call({:read, cursor}, _, s) do
    s = expire(s)

    reply =
      cond do
        cursor == cursor(s) ->
          %{cursor: cursor(s), events: []}

        recoverable?(s, cursor) ->
          {_, seq} = parse_cursor(cursor)

          %{
            cursor: cursor(s),
            events:
              s.ring |> Enum.filter(&(&1.event["local_sequence"] > seq)) |> Enum.map(& &1.event)
          }

        true ->
          %{cursor: cursor(s), events: [reset(s), snapshot(s)]}
      end

    {:reply, reply, s}
  end

  def handle_info(:expire, s) do
    Process.send_after(self(), :expire, 1000)
    {:noreply, expire(s)}
  end

  defp apply_event(s, %{"event" => type} = e) when type in ["message", "replace"] do
    p = if type == "replace", do: e["payload"]["message"], else: e["payload"]
    key = {source(e), e["emission_session"], p["message_id"]}

    blocked =
      Enum.any?(
        [{:message, key}, {:author, source(e), p["author_id"]}, {:channel, source(e)}],
        fn barrier ->
          case Map.get(s.barriers, barrier) do
            nil ->
              false

            {_expires, occurred_at} ->
              match?({:message, _}, barrier) or type == "replace" or
                older?(e["occurred_at"], occurred_at)
          end
        end
      )

    exists = Enum.any?(s.messages, &(&1.key == key))

    cond do
      blocked ->
        {:error, :deleted}

      type == "replace" and not exists ->
        {:error, :missing_message}

      true ->
        message = %{
          key: key,
          source: source(e),
          expires: now() + @history_ms,
          event: Map.put(e, "payload", p) |> Map.put("event", "message")
        }

        next_messages = Enum.reject(s.messages, &(&1.key == key)) ++ [message]
        {evicted, kept} = Enum.split(next_messages, max(0, length(next_messages) - 100))
        # View filters must also receive capacity eviction for their own platform.
        s =
          Enum.reduce(evicted, s, fn old, acc ->
            event =
              Event.new(
                old.event["platform"],
                old.event["channel"],
                "delete_message",
                "evicted-#{System.unique_integer([:positive])}",
                %{"message_id" => old.event["payload"]["message_id"]},
                session: old.event["emission_session"]
              )

            append(acc, event)
          end)

        {:ok, %{s | messages: kept}}
    end
  end

  defp apply_event(s, %{"event" => "source_state"} = e),
    do: {:ok, %{s | states: Map.put(s.states, source(e), e)}}

  defp apply_event(s, e) do
    p = e["payload"]

    {key, reject} =
      case e["event"] do
        "delete_message" ->
          key = {source(e), e["emission_session"], p["message_id"]}
          {{:message, key}, fn m -> m.key == key end}

        "delete_author" ->
          {{:author, source(e), p["author_id"]},
           fn m -> m.source == source(e) and m.event["payload"]["author_id"] == p["author_id"] end}

        "clear_channel" ->
          {{:channel, source(e)}, fn m -> m.source == source(e) end}
      end

    if map_size(s.barriers) < @barriers or Map.has_key?(s.barriers, key) do
      # Missing source times fail closed for history received after a deletion.
      at = e["occurred_at"] || e["received_at"]

      at =
        case Map.get(s.barriers, key) do
          {_, previous} -> if older?(at, previous), do: previous, else: at
          nil -> at
        end

      barrier = {now() + @history_ms, at}

      {:ok,
       %{
         s
         | messages:
             Enum.reject(s.messages, fn m ->
               reject.(m) and
                 (e["event"] == "delete_message" or older?(m.event["occurred_at"], at))
             end),
           barriers: Map.put(s.barriers, key, barrier),
           ring: [],
           sequence: s.sequence + 1
       }}
    else
      # Fail closed under deletion floods: compact into one channel barrier,
      # clear that source and change epoch so every viewer receives the new state.
      barriers =
        Map.new(s.sources, fn src ->
          {{:channel, src}, {now() + @history_ms, e["received_at"]}}
        end)

      states =
        Map.new(s.sources, fn {platform, channel} = src ->
          {src, Event.source_state(platform, channel, "degraded")}
        end)

      {:ok,
       %{
         s
         | messages: [],
           barriers: barriers,
           epoch: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
           sequence: 0,
           ring: [],
           states: states
       }}
    end
  end

  defp older?(nil, _), do: true

  defp older?(at, barrier) do
    {:ok, a, _} = DateTime.from_iso8601(at)
    {:ok, b, _} = DateTime.from_iso8601(barrier)
    DateTime.compare(a, b) != :gt
  end

  defp remember(s, key) do
    seen = Map.put(s.seen, key, true)
    queue = :queue.in(key, s.seen_order)

    if map_size(seen) > @seen do
      {{:value, old}, queue} = :queue.out(queue)
      %{s | seen: Map.delete(seen, old), seen_order: queue}
    else
      %{s | seen: seen, seen_order: queue}
    end
  end

  defp append(s, event) do
    seq = s.sequence + 1

    %{
      s
      | sequence: seq,
        ring:
          Enum.take(
            s.ring ++
              [%{event: Map.put(event, "local_sequence", seq), expires: now() + @history_ms}],
            -@ring
          )
    }
  end

  defp expire(s) do
    t = now()
    messages = Enum.filter(s.messages, &(&1.expires > t))
    barriers = Map.reject(s.barriers, fn {_, {expires, _}} -> expires <= t end)
    next = %{s | messages: messages, barriers: barriers}

    if length(messages) != length(s.messages) or Enum.any?(s.ring, &(&1.expires <= t)),
      do: %{next | sequence: s.sequence + 1, ring: []},
      else: next
  end

  defp snapshot(s),
    do: %{
      "event" => "snapshot",
      "version" => 1,
      "payload" => %{
        "messages" => Enum.map(s.messages, & &1.event),
        "source_states" => Map.values(s.states),
        "cursor" => cursor(s),
        "epoch" => s.epoch
      }
    }

  defp reset(s),
    do: %{
      "event" => "reset",
      "version" => 1,
      "payload" => %{"reason" => "cursor_unavailable", "epoch" => s.epoch}
    }

  defp recoverable?(%{ring: []}, _), do: false

  defp recoverable?(s, cursor) do
    case parse_cursor(cursor) do
      {epoch, seq} ->
        epoch == s.epoch and seq >= hd(s.ring).event["local_sequence"] - 1 and seq <= s.sequence

      _ ->
        false
    end
  end

  defp parse_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 60 do
    case String.split(cursor, ":") do
      [epoch, seq] ->
        case Integer.parse(seq) do
          {n, ""} when n >= 0 -> {epoch, n}
          _ -> :invalid
        end

      _ ->
        :invalid
    end
  end

  defp parse_cursor(_), do: :invalid
  defp cursor(s), do: "#{s.epoch}:#{s.sequence}"
  defp source(e), do: {e["platform"], e["channel"]}
  defp now, do: System.monotonic_time(:millisecond)
end
