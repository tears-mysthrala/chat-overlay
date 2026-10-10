defmodule ChatOverlay.Reauthentication do
  @moduledoc "Operator-enrolled TOTP for sensitive actions; no enrollment via a browser session."
  use GenServer
  alias ChatOverlay.{Config, JSON}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  def consume(session, code, server \\ __MODULE__) do
    GenServer.call(server, {:consume, session, code})
  catch
    :exit, _ -> {:error, :reauthentication_required}
  end

  def load_credentials(nil), do: {:ok, %{}}

  def load_credentials(path) do
    with {:ok, %{type: :regular, size: size, mode: mode}} when size <= 16_384 <- File.lstat(path),
         true <- :os.type() == {:win32, :nt} or Bitwise.band(mode, 0o077) == 0,
         {:ok, body} <- File.read(path),
         {:ok, entries} when is_list(entries) and length(entries) <= 10 <- JSON.decode(body),
         {:ok, credentials} <- decode_credentials(entries),
         true <- map_size(credentials) == length(entries) do
      {:ok, credentials}
    else
      _ -> {:error, :invalid_reauthentication_configuration}
    end
  end

  defp decode_credentials(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      with %{"handle" => handle, "provider" => provider, "user_id" => id, "secret" => secret} <-
             entry,
           true <- map_size(entry) == 4 and Config.handle?(handle),
           true <- provider in ["twitch", "youtube"] and is_binary(id) and byte_size(id) in 1..128,
           true <- is_binary(secret) and byte_size(secret) == 32,
           {:ok, bytes} when byte_size(bytes) == 20 <- Base.decode32(secret, padding: false) do
        {:cont, {:ok, Map.put(acc, handle, %{provider: provider, user_id: id, secret: bytes})}}
      else
        _ -> {:halt, {:error, :invalid_reauthentication_configuration}}
      end
    end)
  end

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.system_time(:second) end)
    path = Keyword.get(opts, :path, Application.get_env(:chat_overlay, :reauth_totp_file))

    with {:ok, credentials} <- load_credentials(path) do
      # A restarted verifier cannot know whether a code in this interval was
      # already consumed. Reject that entire interval; never accept past codes.
      {:ok,
       %{
         credentials: credentials,
         clock: clock,
         ready_at: (div(clock.(), 30) + 1) * 30,
         attempts: %{},
         used: %{}
       }}
    else
      error -> {:stop, elem(error, 1)}
    end
  end

  @impl true
  def handle_call({:consume, session, code}, _from, state) do
    now = state.clock.()
    handle = session["handle"]
    credential = state.credentials[handle]

    cond do
      is_nil(credential) ->
        {:reply, {:error, :reauthentication_not_configured}, state}

      session["provider"] != credential.provider or session["user_id"] != credential.user_id ->
        {:reply, {:error, :reauthentication_required}, state}

      now < state.ready_at ->
        {:reply, {:error, :reauthentication_required}, state}

      true ->
        {start, count} = Map.get(state.attempts, handle, {now, 0})
        {start, count} = if now - start >= 300, do: {now, 0}, else: {start, count}

        if count >= 5 do
          {:reply, {:error, :reauthentication_rate_limited}, state}
        else
          state = %{state | attempts: Map.put(state.attempts, handle, {start, count + 1})}

          if is_binary(code) and byte_size(code) == 6 and
               NimbleTOTP.valid?(credential.secret, code, time: now, since: state.used[handle]) do
            {:reply, :ok, %{state | used: Map.put(state.used, handle, now)}}
          else
            {:reply, {:error, :reauthentication_required}, state}
          end
        end
    end
  end

  # OTP/sys diagnostics must not expose factor seeds or the submitted code.
  @impl true
  def format_status(_status),
    do: %{state: :redacted, message: :redacted, reason: :redacted, log: []}
end
