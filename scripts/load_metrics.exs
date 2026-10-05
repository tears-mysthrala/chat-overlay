defmodule ChatOverlay.LoadMetrics do
  @moduledoc "Bounded synthetic-load measurements; no chat payloads or credentials."
  @max_bucket_ms 1_000

  @doc "Records latency rounded up to milliseconds, with overflow capped at the final bucket."
  def record_latency(table, microseconds) when microseconds >= 0 do
    # Use a conservative upper estimate instead of claiming sub-millisecond precision.
    bucket = min(div(microseconds + 999, 1_000), @max_bucket_ms)
    :ets.update_counter(table, :samples, 1, {:samples, 0})
    :ets.update_counter(table, {:bucket_ms, bucket}, {2, 1}, {{:bucket_ms, bucket}, 0})
  end

  @doc "Returns the 95th ranked bucket; nil for no samples, 1000 for the capped tail."
  def p95(table) do
    samples = :ets.lookup_element(table, :samples, 2)

    if samples == 0 do
      nil
    else
      target = div(samples * 95 + 99, 100)

      table
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{:bucket_ms, ms}, count} -> [{ms, count}]
        _ -> []
      end)
      |> Enum.sort()
      |> Enum.reduce_while(0, fn {ms, count}, total ->
        if total + count >= target,
          do: {:halt, ms},
          else: {:cont, total + count}
      end)
    end
  end

  @doc "Replaces a sample slot with current BEAM resources and delivery counters."
  def snapshot(table, slot, elapsed_ms) do
    point = %{
      elapsed_ms: elapsed_ms,
      memory_total_bytes: :erlang.memory(:total),
      process_count: :erlang.system_info(:process_count),
      received_samples: :ets.lookup_element(table, :samples, 2),
      errors: :ets.lookup_element(table, :errors, 2)
    }

    :ets.insert(table, {{:resource_sample, slot}, point})
    point
  end

  @doc "Returns bounded periodic resource samples in elapsed-time order."
  def resource_samples(table) do
    table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{:resource_sample, _}, point} -> [point]
      _ -> []
    end)
    |> Enum.sort_by(& &1.elapsed_ms)
  end
end
