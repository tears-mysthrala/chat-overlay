Code.require_file("../scripts/load_metrics.exs", __DIR__)

defmodule ChatOverlay.LoadMetricsTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.LoadMetrics

  setup do
    table = :ets.new(:metrics, [:set])
    :ets.insert(table, [{:samples, 0}, {:errors, 0}])
    %{table: table}
  end

  test "empty measurement has no percentile", %{table: table} do
    assert LoadMetrics.p95(table) == nil
  end

  test "rounds up latency at the strict acceptance boundary", %{table: table} do
    LoadMetrics.record_latency(table, 99_001)
    assert LoadMetrics.p95(table) == 100
  end

  test "selects the 95th ranked sample", %{table: table} do
    for _ <- 1..94, do: LoadMetrics.record_latency(table, 1_000)
    LoadMetrics.record_latency(table, 49_001)
    for _ <- 1..5, do: LoadMetrics.record_latency(table, 900_000)
    assert LoadMetrics.p95(table) == 50
    assert :ets.lookup_element(table, :samples, 2) == 100
  end

  test "histogram stays bounded even with increasing delays", %{table: table} do
    for ms <- 0..5_000, do: LoadMetrics.record_latency(table, ms * 1_000)
    assert :ets.info(table, :size) == 1_003
    assert LoadMetrics.p95(table) == 1_000
    assert :ets.lookup_element(table, {:bucket_ms, 1_000}, 2) == 4_001
  end

  test "resource samples replace a slot and preserve final chronology", %{table: table} do
    LoadMetrics.snapshot(table, 0, 0)
    :ets.update_counter(table, :samples, 10)
    LoadMetrics.snapshot(table, 0, 1)
    LoadMetrics.snapshot(table, :final, 20)
    assert [first, last] = LoadMetrics.resource_samples(table)
    assert first.elapsed_ms == 1
    assert last.elapsed_ms == 20
    assert first.received_samples == 10
    assert last.errors == 0
    assert last.memory_total_bytes > 0
    assert last.process_count > 0
  end
end
