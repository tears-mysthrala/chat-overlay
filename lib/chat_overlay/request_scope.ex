defmodule ChatOverlay.RequestScope do
  @moduledoc "Server-derived request scope, cleared even on exceptions; no client context header."
  @key {__MODULE__, :scope}
  def current, do: Process.get(@key, :service)
  def request(fun), do: with_scope(:unverified, fun)

  def with_scope(scope, fun) do
    previous = Process.get(@key)
    Process.put(@key, scope)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  def grant(handle) do
    if Process.get(@key) != nil, do: Process.put(@key, {:profile, handle})
    :ok
  end
end
