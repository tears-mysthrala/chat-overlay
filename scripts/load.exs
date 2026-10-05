Code.require_file("../test/support/http_client.ex", __DIR__)
Code.require_file("load_metrics.exs", __DIR__)
alias ChatOverlay.LoadMetrics
# Synthetic, bounded HTTP/SSE exercise; never contacts a platform.
# MIX_ENV=test mix run --no-start scripts/load.exs [seconds]
seconds =
  case System.argv() do
    [value] -> String.to_integer(value)
    [] -> 30
  end

if seconds not in 10..86_400, do: raise("duration must be 10..86400 seconds")
Application.load(:chat_overlay)

profiles =
  for n <- 1..10 do
    %{
      "handle" => "load-#{n}",
      "sources" =>
        for(
          platform <- ~w(twitch youtube kick),
          do: %{"platform" => platform, "channel" => "source-#{n}-#{platform}", "mode" => "demo"}
        )
    }
  end

Application.put_env(:chat_overlay, :profiles, profiles)
Application.put_env(:chat_overlay, :http, true)
Application.put_env(:chat_overlay, :port, 0)
Application.put_env(:chat_overlay, :grace_ms, 30)
{:ok, _} = Application.ensure_all_started(:chat_overlay)
port = ChatOverlay.HTTP.port()
metrics = :ets.new(:load_metrics, [:public, :set, write_concurrency: true])
:ets.insert(metrics, [{:samples, 0}, {:errors, 0}])

defmodule LoadReader do
  def start(parent, port, handle, metrics) do
    {:ok, conn} =
      ChatOverlay.TestClient.open(~c"127.0.0.1", port, %{retry: 0, protocols: [:http]})

    {:ok, _} = ChatOverlay.TestClient.await_up(conn)
    ref = ChatOverlay.TestClient.get(conn, "/events/#{handle}")

    case ChatOverlay.TestClient.await(conn, ref) do
      {:response, :nofin, 200, _} ->
        bootstrap(conn, ref, "")
        send(parent, :reader_ready)
        loop(conn, ref, "", metrics)

      failure ->
        :ets.update_counter(metrics, :errors, 1)
        send(parent, {:reader_failed, failure})
    end
  end

  defp bootstrap(conn, ref, buffer) do
    {:data, :nofin, data} = ChatOverlay.TestClient.await(conn, ref, 5000)
    buffer = buffer <> data

    if not (String.contains?(buffer, "event: batch") and String.ends_with?(buffer, "\n\n")),
      do: bootstrap(conn, ref, buffer)
  end

  defp loop(conn, ref, buffer, metrics) do
    receive do
      {:client_data, ^conn, ^ref, :nofin, data} ->
        chunks = String.split(buffer <> data, "\n\n")
        Enum.each(Enum.drop(chunks, -1), &measure(&1, metrics))
        rest = List.last(chunks)
        if byte_size(rest) > 4_194_304, do: raise("unbounded frame")
        loop(conn, ref, rest, metrics)

      :stop ->
        if buffer != "" and String.contains?(buffer, "data: ") do
          measure(buffer, metrics)
        end

        ChatOverlay.TestClient.close(conn)

      {:client_down, ^conn, _, _, _} ->
        :ets.update_counter(metrics, :errors, 1)

      _ ->
        loop(conn, ref, buffer, metrics)
    after
      20_000 ->
        :ets.update_counter(metrics, :errors, 1)
        ChatOverlay.TestClient.close(conn)
    end
  end

  defp measure(frame, metrics) do
    Enum.each(String.split(frame, "\n"), fn
      "data: " <> data ->
        %{"events" => events} = JSON.decode!(data)

        Enum.each(events, fn event ->
          case event do
            %{"event" => "message", "upstream_id" => "load-warmup"} ->
              :ets.insert(metrics, {{:ready_reader, self()}, true})

            %{"event" => "snapshot", "payload" => %{"messages" => messages}} ->
              if Enum.any?(messages, &(&1["upstream_id"] == "load-warmup")) do
                :ets.insert(metrics, {{:ready_reader, self()}, true})
              end

            %{"event" => "message", "upstream_id" => "load:" <> sent} ->
              {start, ""} = Integer.parse(sent)
              us = System.monotonic_time(:microsecond) - start
              LoadMetrics.record_latency(metrics, us)

            _ ->
              :ok
          end
        end)

      _ ->
        :ok
    end)
  end
end

parent = self()

readers =
  for n <- 0..99 do
    spawn_link(fn -> LoadReader.start(parent, port, "load-#{rem(n, 10) + 1}", metrics) end)
  end

for _ <- readers do
  receive do
    :reader_ready -> :ok
    {:reader_failed, reason} -> raise "viewer rejected: #{inspect(reason)}"
  after
    15_000 -> raise "viewer startup timeout"
  end
end

# Source demand starts asynchronously and Kick's initial clear invalidates replay.
# Start measurement only after workers and every reader have crossed that barrier.
ready_deadline = System.monotonic_time(:millisecond) + 15_000

await_ready = fn await_ready, predicate ->
  cond do
    predicate.() ->
      :ok

    System.monotonic_time(:millisecond) >= ready_deadline ->
      raise "load warmup timeout"

    true ->
      Process.sleep(25)
      await_ready.(await_ready, predicate)
  end
end

await_ready.(await_ready, fn ->
  Enum.all?(profiles, fn profile ->
    Enum.all?(profile["sources"], &ChatOverlay.Source.active?/1)
  end)
end)

for profile <- profiles do
  source = hd(profile["sources"])

  warmup =
    ChatOverlay.Event.new(source["platform"], source["channel"], "message", "load-warmup", %{
      "message_id" => "load-warmup",
      "author_id" => "synthetic",
      "author_display" => "Warmup",
      "text" => "Warmup"
    })

  :ok = ChatOverlay.Store.ingest(ChatOverlay.Store.name(profile["handle"]), warmup)
end

await_ready.(await_ready, fn ->
  :ets.select_count(metrics, [{{{:ready_reader, :_}, true}, [], [true]}]) == 100
end)

memory_before = :erlang.memory(:total)
start = System.monotonic_time(:millisecond)
started_at = DateTime.to_iso8601(DateTime.utc_now())
LoadMetrics.snapshot(metrics, 0, 0)
finish = start + seconds * 1000
text = String.duplicate("x", 512)

emit = fn emit, n, last_sample_slot ->
  now = System.monotonic_time(:millisecond)

  if now < finish do
    sample_slot = div(now - start, 60_000)

    if sample_slot > last_sample_slot do
      LoadMetrics.snapshot(metrics, sample_slot, now - start)
    end

    profile = Enum.at(profiles, rem(n, 10))
    source = Enum.at(profile["sources"], rem(div(n, 10), 3))
    id = "load:#{System.monotonic_time(:microsecond)}"

    event =
      ChatOverlay.Event.new(
        source["platform"],
        source["channel"],
        "message",
        id,
        %{
          "message_id" => id,
          "author_id" => "synthetic",
          "author_display" => "Load",
          "text" => text
        },
        occurred_at: DateTime.to_iso8601(DateTime.utc_now())
      )

    :ok = ChatOverlay.Store.ingest(ChatOverlay.Store.name(profile["handle"]), event)
    # 200/s for the first 10 seconds, then 50/s; demo adds a small declared overhead.
    due = start + if(n + 1 < 2000, do: (n + 1) * 5, else: 10_000 + (n + 1 - 2000) * 20)
    Process.sleep(max(0, due - System.monotonic_time(:millisecond)))
    emit.(emit, n + 1, sample_slot)
  else
    n
  end
end

emitted = emit.(emit, 0, 0)
expected = emitted * 10
drain_deadline = System.monotonic_time(:millisecond) + 10_000

drain = fn drain ->
  samples = :ets.lookup_element(metrics, :samples, 2)

  if samples < expected and System.monotonic_time(:millisecond) < drain_deadline do
    Process.sleep(25)
    drain.(drain)
  else
    :ok
  end
end

drain.(drain)
monitors = Enum.map(readers, &{&1, Process.monitor(&1)})
Enum.each(readers, &send(&1, :stop))

Enum.each(monitors, fn {reader, monitor} ->
  receive do
    {:DOWN, ^monitor, :process, ^reader, _reason} -> :ok
  after
    5_000 -> raise "reader shutdown timeout"
  end
end)

samples = :ets.lookup_element(metrics, :samples, 2)
p95 = LoadMetrics.p95(metrics)
LoadMetrics.snapshot(metrics, :final, System.monotonic_time(:millisecond) - start)
resource_samples = LoadMetrics.resource_samples(metrics)

report = %{
  duration_seconds: seconds,
  actual_elapsed_ms: System.monotonic_time(:millisecond) - start,
  started_at_utc: started_at,
  finished_at_utc: DateTime.to_iso8601(DateTime.utc_now()),
  source_commit: System.get_env("LOAD_SOURCE_COMMIT"),
  profiles: 10,
  sources: 30,
  readers: 100,
  emitted: emitted,
  received_samples: samples,
  expected_samples: emitted * 10,
  errors: :ets.lookup_element(metrics, :errors, 2),
  p95_local_to_sse_ms: p95,
  memory_before_bytes: memory_before,
  memory_after_bytes: :erlang.memory(:total),
  resource_sample_interval_seconds: 60,
  resource_samples: resource_samples,
  memory_peak_sampled_bytes: Enum.max(Enum.map(resource_samples, & &1.memory_total_bytes)),
  latency_bucket_upper_bound_ms: 1_000,
  latency_buckets_rounding: "ceiling; >999ms accumulated in final bucket (overflow capped)",
  elixir: System.version(),
  otp: List.to_string(:erlang.system_info(:otp_release)),
  schedulers: :erlang.system_info(:schedulers_online),
  includes_synthetic_demo_overhead: true,
  excludes: ["upstream", "OBS", "browser", "Internet", "cloudflared"]
}

IO.puts(JSON.encode!(report))

if samples != emitted * 10 or report.errors != 0 or is_nil(p95) or p95 >= 100,
  do: System.halt(1)
