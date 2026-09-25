defmodule ChatOverlay do
  @moduledoc "Read-only F1 chat overlay with bounded in-memory state and official connectors."
  @doc "Returns the implemented product phase; publication has separate validation gates."
  @spec phase() :: :f1
  def phase, do: :f1
end
