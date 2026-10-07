defmodule ChatOverlay.RequestScope do
  @moduledoc "Server-derived request scope, cleared even on exceptions; no client context header."
  @key {__MODULE__, :scope}
  @authorizer {__MODULE__, :authorizer}
  def current, do: Process.get(@key, :service)
  def authorizer, do: Process.get(@authorizer, fn -> :ok end)

  def with_authorizer(authorizer, fun) when is_function(authorizer, 0) do
    previous = Process.get(@authorizer)
    Process.put(@authorizer, authorizer)

    try do
      fun.()
    after
      if previous, do: Process.put(@authorizer, previous), else: Process.delete(@authorizer)
    end
  end

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
