defmodule ChatOverlay.Admission do
  @moduledoc "Global SSE admission and source demand. Monitors own every viewer lease."
  use GenServer
  alias ChatOverlay.{Config, Source}
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def acquire(handle), do: GenServer.call(__MODULE__, {:acquire, self(), handle})
  def release, do: GenServer.call(__MODULE__, {:release, self()})
  def demand_count(source), do: GenServer.call(__MODULE__, {:demand, source})
  def init(_), do: {:ok, %{viewers: %{}, counts: %{}}}

  def handle_call({:demand, source}, _, s) do
    count = Enum.count(Config.handles(source), &(Map.get(s.counts, &1, 0) > 0))
    {:reply, count, s}
  end

  def handle_call({:release, pid}, _, s) do
    refs = for {ref, {owner, _}} <- s.viewers, owner == pid, do: ref

    next =
      Enum.reduce(refs, s, fn ref, state ->
        Process.demonitor(ref, [:flush])
        {:noreply, state} = handle_info({:DOWN, ref, :process, pid, :normal}, state)
        state
      end)

    {:reply, :ok, next}
  end

  def handle_call({:acquire, pid, handle}, _, s) do
    cond do
      is_nil(Config.profile(handle)) ->
        {:reply, {:error, :not_found}, s}

      map_size(s.viewers) >= 100 ->
        {:reply, {:error, :capacity}, s}

      true ->
        ref = Process.monitor(pid)
        count = Map.get(s.counts, handle, 0)
        if count == 0, do: demand(handle, :acquire)

        {:reply, :ok,
         %{
           s
           | viewers: Map.put(s.viewers, ref, {pid, handle}),
             counts: Map.put(s.counts, handle, count + 1)
         }}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Map.pop(s.viewers, ref) do
      {nil, _} ->
        {:noreply, s}

      {{_pid, handle}, viewers} ->
        count = s.counts[handle] - 1
        if count == 0, do: demand(handle, :release)
        {:noreply, %{s | viewers: viewers, counts: Map.put(s.counts, handle, count)}}
    end
  end

  defp demand(handle, action) do
    Enum.each(Config.profile(handle)["sources"], fn source -> Source.demand(source, action) end)
  end
end
