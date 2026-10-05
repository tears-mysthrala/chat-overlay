defmodule ChatOverlay.MediaCleanup do
  @moduledoc "Retries one expired reservation or retired object per tick; the ledger survives restarts."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  def handle_info(:cleanup, state) do
    objects = due_objects()
    object = Enum.find(objects, &(is_nil(state) or &1["key"] > state)) || List.first(objects)
    if object, do: ChatOverlay.Profiles.cleanup_media(object["key"])
    schedule()
    {:noreply, if(object, do: object["key"], else: nil)}
  end

  def sweep_one do
    case List.first(due_objects()) do
      nil -> :ok
      object -> ChatOverlay.Profiles.cleanup_media(object["key"])
    end
  end

  defp due_objects do
    now = System.system_time(:second)

    ChatOverlay.Profiles.media_objects()
    |> Enum.filter(&ChatOverlay.MediaLedger.due?(&1, now))
    |> Enum.sort_by(& &1["key"])
  end

  defp schedule, do: Process.send_after(self(), :cleanup, 30_000)
end
