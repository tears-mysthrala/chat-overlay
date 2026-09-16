defmodule ChatOverlay.Application do
  @moduledoc """
  Minimal F0 supervision tree.

  F0 deliberately exposes no network listener or platform connector.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = []
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
