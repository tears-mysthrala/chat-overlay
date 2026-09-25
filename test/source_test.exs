defmodule ChatOverlay.SourceTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Source, Config, Admission}

  test "upstream retry deadline survives idle grace and resumed demand" do
    source = hd(Config.profile("test")["sources"])
    {:ok, s} = Source.init(source)
    ref = make_ref()

    {:noreply, waiting} =
      Source.handle_info({ref, {:retry, 3_600_000}}, %{
        s
        | worker: %Task{ref: ref, pid: self(), owner: self(), mfa: nil},
          demand: 1
      })

    Process.cancel_timer(waiting.timer)
    {:noreply, idle} = Source.handle_info(:idle, %{waiting | demand: 0})
    assert idle.next_attempt == waiting.next_attempt
    assert idle.worker == nil and idle.timer == nil
    assert :ok = Admission.acquire("test")

    try do
      {:noreply, resumed} = Source.handle_cast(:acquire, idle)
      assert resumed.worker == nil
      assert is_reference(resumed.timer)
      assert resumed.next_attempt - System.monotonic_time(:millisecond) >= 3_599_000
      Process.cancel_timer(resumed.timer)
    after
      Admission.release()
    end
  end

  test "successful poll interval survives idle shutdown too" do
    source = hd(Config.profile("test")["sources"])
    {:ok, s} = Source.init(source)
    worker = %Task{ref: make_ref(), pid: self(), owner: self(), mfa: nil}

    {:reply, :ok, waiting} =
      Source.handle_call({:defer, 300_000}, {self(), make_ref()}, %{s | worker: worker})

    # Model completed worker shutdown without terminating the test owner.
    {:noreply, idle} = Source.handle_info(:idle, %{waiting | worker: nil})
    assert idle.next_attempt == waiting.next_attempt
    assert :ok = Admission.acquire("test")

    try do
      {:noreply, resumed} = Source.handle_cast(:acquire, idle)
      assert resumed.worker == nil
      assert resumed.next_attempt - System.monotonic_time(:millisecond) >= 299_000
      Process.cancel_timer(resumed.timer)
    after
      Admission.release()
    end
  end

  test "kick source tracks gap state across idle transitions" do
    kick_source = %{"platform" => "kick", "channel" => "testkick", "mode" => "demo"}
    {:ok, s} = Source.init(kick_source)
    assert s.gap == true

    {:noreply, idle} = Source.handle_info(:idle, %{s | gap: false, demand: 0})
    assert idle.gap == true
  end
end
