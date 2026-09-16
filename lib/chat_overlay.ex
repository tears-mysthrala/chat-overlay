defmodule ChatOverlay do
  @moduledoc """
  F0 executable boundary for chat-overlay.

  Platform adapters, web transport, persistence, accounts and bots are
  intentionally out of scope until their own approved issues.
  """

  @doc "Returns the current bootstrap phase."
  @spec phase() :: :f0
  def phase, do: :f0
end
