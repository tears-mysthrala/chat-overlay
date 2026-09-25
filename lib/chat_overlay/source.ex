defmodule ChatOverlay.Source do
  @moduledoc "Supervised source lease, cancelable worker, bounded retry and viewer grace."
  use GenServer
  alias ChatOverlay.{Config, Event, Store}

  def child_spec(source),
    do: %{id: {:source, Config.key(source)}, start: {__MODULE__, :start_link, [source]}}

  def start_link(source), do: GenServer.start_link(__MODULE__, source, name: name(source))
  def name(source), do: {:via, Registry, {ChatOverlay.Registry, {:source, Config.key(source)}}}
  def demand(source, action), do: GenServer.cast(name(source), action)
  def active?(source), do: GenServer.call(name(source), :active)

  def defer(source, milliseconds) do
    case GenServer.whereis(name(source)) do
      nil -> :ok
      pid -> GenServer.call(pid, {:defer, milliseconds})
    end
  end

  def publish(source, event) do
    Config.handles(source)
    |> Enum.map(&Store.ingest(Store.name(&1), event))
    |> Enum.all?(&(&1 in [:ok, :duplicate, {:error, :deleted}, {:error, :missing_message}]))
  end

  def status(source, status),
    do: publish(source, Event.source_state(source["platform"], source["channel"], status))

  def init(source) do
    Process.flag(:trap_exit, true)
    send(self(), :restore)
    status(source, "offline")

    {:ok,
     %{
       source: source,
       demand: 0,
       worker: nil,
       timer: nil,
       grace: nil,
       attempts: 0,
       next_attempt: nil,
       started: nil,
       gap: true
     }}
  end

  def format_status(status), do: Map.put(status, :state, :redacted_source_state)
  def handle_call(:active, _, s), do: {:reply, s.worker != nil, s}

  def handle_call({:defer, ms}, {pid, _}, %{worker: %Task{pid: pid}} = s)
      when ms in 1..3_600_000 do
    due = System.monotonic_time(:millisecond) + ms
    {:reply, :ok, %{s | next_attempt: max(s.next_attempt || due, due)}}
  end

  def handle_call({:defer, _}, _, s), do: {:reply, {:error, :not_owner}, s}

  def handle_cast(action, s) when action in [:acquire, :release] do
    if s.grace, do: Process.cancel_timer(s.grace)
    count = ChatOverlay.Admission.demand_count(s.source)

    s =
      if count > 0 and s.source["platform"] == "kick" and Map.get(s, :gap, true) do
        clear =
          Event.new(
            s.source["platform"],
            s.source["channel"],
            "clear_channel",
            "gap-#{System.unique_integer([:positive])}",
            %{"scope" => "channel"}
          )

        publish(s.source, clear)
        %{s | gap: false}
      else
        s
      end

    grace =
      if count == 0,
        do:
          Process.send_after(self(), :idle, Application.get_env(:chat_overlay, :grace_ms, 60_000))

    s = %{s | demand: count, grace: grace}

    {:noreply,
     if(count > 0 and s.worker == nil and s.timer == nil, do: ensure_worker(s), else: s)}
  end

  def handle_info(:restore, s) do
    handle_cast(:acquire, s)
  end

  def handle_info(:idle, %{demand: 0} = s) do
    if s.worker, do: Task.shutdown(s.worker, :brutal_kill)
    if s.timer, do: Process.cancel_timer(s.timer)
    status(s.source, "offline")
    {:noreply, %{s | worker: nil, timer: nil, grace: nil, gap: true}}
  end

  def handle_info(:idle, s), do: {:noreply, s}

  def handle_info({:retry, due}, %{next_attempt: due, worker: nil} = s) do
    remaining = due - System.monotonic_time(:millisecond)

    cond do
      s.demand == 0 ->
        {:noreply, %{s | timer: nil}}

      remaining > 0 ->
        {:noreply,
         %{s | timer: Process.send_after(self(), {:retry, due}, min(remaining, 60_000))}}

      true ->
        {:noreply, launch(%{s | timer: nil})}
    end
  end

  def handle_info({ref, result}, %{worker: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])

    {state, minimum} =
      case result do
        {:stop, :configuration_error} -> {"configuration_error", 60_000}
        {:stop, :offline} -> {"offline", 60_000}
        {:retry, ms} when is_integer(ms) and ms >= 0 -> {"degraded", ms}
        _ -> {"degraded", 1000}
      end

    status(s.source, state)

    attempts =
      if System.monotonic_time(:millisecond) - (s.started || 0) > 300_000, do: 0, else: s.attempts

    delay =
      max(minimum, min(60_000, 1000 * Integer.pow(2, min(attempts, 6)))) + :rand.uniform(500)

    due =
      max(
        s.next_attempt || System.monotonic_time(:millisecond),
        System.monotonic_time(:millisecond) + delay
      )

    timer =
      if s.demand > 0,
        do:
          Process.send_after(
            self(),
            {:retry, due},
            min(due - System.monotonic_time(:millisecond), 60_000)
          )

    {:noreply,
     %{
       s
       | worker: nil,
         timer: timer,
         attempts: min(attempts + 1, 6),
         next_attempt: due,
         started: nil
     }}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{worker: %Task{ref: ref}} = s) do
    handle_info({ref, {:retry, 1000}}, s)
  end

  def handle_info(_, s), do: {:noreply, s}

  defp ensure_worker(s) do
    now = System.monotonic_time(:millisecond)

    if s.next_attempt && s.next_attempt > now do
      %{
        s
        | timer:
            Process.send_after(
              self(),
              {:retry, s.next_attempt},
              min(s.next_attempt - now, 60_000)
            )
      }
    else
      launch(s)
    end
  end

  defp launch(s) do
    # After an upstream gap, old content may have been deleted while disconnected.
    # Clear it before reconnecting; never imply recovery of events upstream cannot replay.
    # For polling/websocket platforms, every launch implies reconnecting after a gap.
    # For webhook platforms (Kick), gap cleanup happens in handle_cast upon demand resume,
    # before incoming webhooks are accepted, preventing wiping of newly received messages.
    if s.source["platform"] != "kick" do
      clear =
        Event.new(
          s.source["platform"],
          s.source["channel"],
          "clear_channel",
          "gap-#{System.unique_integer([:positive])}",
          %{"scope" => "channel"}
        )

      publish(s.source, clear)
    end

    status(s.source, "connecting")
    source = s.source

    worker =
      Task.Supervisor.async(ChatOverlay.Tasks, fn ->
        try do
          if source["mode"] == "demo",
            do: ChatOverlay.Connectors.demo(source),
            else: ChatOverlay.Connectors.run(source)
        rescue
          _ -> {:retry, 5000}
        catch
          _, _ -> {:retry, 5000}
        end
      end)

    %{
      s
      | worker: worker,
        next_attempt: nil,
        started: System.monotonic_time(:millisecond)
    }
  end

  def terminate(_, s) do
    if s.worker, do: Task.shutdown(s.worker, :brutal_kill)
    :ok
  end
end
