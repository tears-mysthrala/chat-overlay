defmodule ChatOverlay.Tokens do
  @moduledoc """
  Concurrency-safe OAuth token coordinator and proactive renewal engine (SEC-15).

  Guarantees:
  1. Stampede protection: Multiple concurrent requests for `{handle, provider}` are
     coalesced into a single upstream OAuth refresh request.
  2. In-memory caching: Valid access tokens are cached until nearing expiration.
  3. Proactive renewal: Refreshes tokens automatically if remaining lifetime is below
     margin (default: 300s).
  4. Token rotation & Google refresh_token preservation: Safely preserves refresh_token
     when upstream omits it.
  5. AEAD encryption at rest: All updated tokens are encrypted and persisted via `ChatOverlay.Profiles`.
  6. Revocation handling: Marks accounts as `reauth_required` upon `:invalid_grant` or revocation.
  """

  use GenServer

  alias ChatOverlay.{OAuth, Profiles}

  @default_margin_seconds 300
  @default_call_timeout 15_000

  # Client API

  @doc "Starts the token coordinator GenServer."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Retrieves a valid OAuth access token for `{handle, provider}`.
  Performs proactive renewal if the token is expired or within `margin_seconds` of expiring.
  Coalesces concurrent requests to prevent upstream stampedes.
  """
  @spec get_access_token(String.t(), String.t() | atom(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def get_access_token(handle, provider, opts \\ []) when is_binary(handle) do
    timeout = Keyword.get(opts, :timeout, @default_call_timeout)
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get_access_token, handle, to_string(provider), opts}, timeout)
  end

  @doc "Invalidates any in-memory cached token for `{handle, provider}`."
  @spec invalidate(String.t(), String.t() | atom(), keyword()) :: :ok
  def invalidate(handle, provider, opts \\ []) when is_binary(handle) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:invalidate, handle, to_string(provider)})
  end

  @doc "Clears all in-memory token cache (useful for testing and security flush)."
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :clear)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = %{
      # %{{handle, provider} => %{access_token: binary, expires_at: integer}}
      cache: %{},
      # %{{handle, provider} => [caller_from, ...]}
      in_flight: %{},
      # %{pid => {ref, {handle, provider}}}
      tasks: %{},
      # %{ref => pid}
      refs: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get_access_token, handle, provider_str, opts}, from, state) do
    key = {handle, provider_str}
    now = System.system_time(:second)
    margin = Keyword.get(opts, :margin_seconds, @default_margin_seconds)
    force? = Keyword.get(opts, :force_refresh, false)

    cached = Map.get(state.cache, key)

    cond do
      # 1. Valid cached token in memory and not forcing refresh
      not force? and is_map(cached) and cached.expires_at - now > margin ->
        {:reply, {:ok, cached.access_token}, state}

      # 2. Upstream refresh already in-flight for this key -> coalesce caller
      Map.has_key?(state.in_flight, key) ->
        callers = Map.get(state.in_flight, key, [])
        new_in_flight = Map.put(state.in_flight, key, [from | callers])
        {:noreply, %{state | in_flight: new_in_flight}}

      # 3. Not in-flight; check stored credentials in profile
      true ->
        case Profiles.get_linked_account_auth(handle, provider_str) do
          {:error, _} = err ->
            {:reply, err, state}

          {:ok, %{account: account, tokens: tokens}} ->
            # If account already marked as reauth_required and not forcing refresh
            if account["status"] == "reauth_required" and not force? do
              {:reply, {:error, :reauth_required}, state}
            else
              stored_expires_at =
                tokens["expires_at"] || now + (tokens["expires_in"] || 0)

              stored_token = tokens["access_token"] || tokens[:access_token]

              if not force? and is_binary(stored_token) and stored_expires_at - now > margin do
                # Stored token is still fresh! Prime cache and reply immediately.
                new_cache =
                  Map.put(state.cache, key, %{
                    access_token: stored_token,
                    expires_at: stored_expires_at
                  })

                {:reply, {:ok, stored_token}, %{state | cache: new_cache}}
              else
                # Stored token is expired or within renewal margin -> launch background refresh
                refresh_token = tokens["refresh_token"] || tokens[:refresh_token]

                if not (is_binary(refresh_token) and byte_size(refresh_token) > 0) do
                  {:reply, {:error, :no_refresh_token}, state}
                else
                  server = self()
                  http_client = opts[:http_client]

                  {pid, ref} =
                    spawn_monitor(fn ->
                      do_background_refresh(
                        server,
                        key,
                        handle,
                        provider_str,
                        refresh_token,
                        http_client
                      )
                    end)

                  new_in_flight = Map.put(state.in_flight, key, [from])
                  new_tasks = Map.put(state.tasks, pid, {ref, key})
                  new_refs = Map.put(state.refs, ref, pid)

                  {:noreply,
                   %{state | in_flight: new_in_flight, tasks: new_tasks, refs: new_refs}}
                end
              end
            end
        end
    end
  end

  @impl true
  def handle_call({:invalidate, handle, provider_str}, _from, state) do
    key = {handle, provider_str}
    new_cache = Map.delete(state.cache, key)
    {:reply, :ok, %{state | cache: new_cache}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | cache: %{}}}
  end

  @impl true
  def handle_info({:worker_done, pid, key, result}, state) do
    case Map.pop(state.tasks, pid) do
      {nil, _} ->
        {:noreply, state}

      {{ref, ^key}, new_tasks} ->
        Process.demonitor(ref, [:flush])
        new_refs = Map.delete(state.refs, ref)
        waiting = Map.get(state.in_flight, key, [])
        new_in_flight = Map.delete(state.in_flight, key)

        case result do
          {:success, access_token, expires_at} ->
            Enum.each(waiting, fn caller ->
              GenServer.reply(caller, {:ok, access_token})
            end)

            new_cache =
              Map.put(state.cache, key, %{
                access_token: access_token,
                expires_at: expires_at
              })

            {:noreply,
             %{
               state
               | in_flight: new_in_flight,
                 tasks: new_tasks,
                 refs: new_refs,
                 cache: new_cache
             }}

          {:failed, error_reply} ->
            Enum.each(waiting, fn caller ->
              GenServer.reply(caller, error_reply)
            end)

            new_cache = Map.delete(state.cache, key)

            {:noreply,
             %{
               state
               | in_flight: new_in_flight,
                 tasks: new_tasks,
                 refs: new_refs,
                 cache: new_cache
             }}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {^pid, new_refs} ->
        {{^ref, key}, new_tasks} = Map.pop(state.tasks, pid)
        waiting = Map.get(state.in_flight, key, [])

        Enum.each(waiting, fn caller ->
          GenServer.reply(caller, {:error, {:worker_crashed, reason}})
        end)

        new_in_flight = Map.delete(state.in_flight, key)
        new_cache = Map.delete(state.cache, key)

        {:noreply,
         %{state | in_flight: new_in_flight, tasks: new_tasks, refs: new_refs, cache: new_cache}}
    end
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  # Background Worker

  defp do_background_refresh(server, key, handle, provider_str, refresh_token, http_client) do
    opts = if http_client, do: [http_client: http_client], else: []

    result =
      case OAuth.refresh_tokens(provider_str, refresh_token, opts) do
        {:ok, new_tokens} ->
          case Profiles.update_tokens(handle, provider_str, new_tokens) do
            {:ok, _} ->
              access_token = new_tokens["access_token"] || new_tokens[:access_token]
              expires_in = new_tokens["expires_in"] || new_tokens[:expires_in] || 3600
              now = System.system_time(:second)
              expires_at = now + expires_in
              {:success, access_token, expires_at}

            {:error, reason} ->
              {:failed, {:error, {:save_failed, reason}}}
          end

        {:error, :invalid_grant} ->
          Profiles.mark_account_reauth_required(handle, provider_str, :invalid_grant)
          {:failed, {:error, :reauth_required}}

        {:error, reason} ->
          {:failed, {:error, reason}}
      end

    send(server, {:worker_done, self(), key, result})
  rescue
    e ->
      send(
        server,
        {:worker_done, self(), key,
         {:failed, {:error, {:refresh_exception, Exception.message(e)}}}}
      )
  end
end
