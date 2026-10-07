defmodule ChatOverlay.OAuthFlow do
  @moduledoc "Bounded browser-bound single-use OAuth transactions; restart cancels pending flows."
  use GenServer
  alias ChatOverlay.{Config, OAuth, Session, Transport}
  @ttl 600
  @limit 1024
  @anonymous_limit 512
  @profile_limit 8
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Separate host-only cookies preserve concurrent first transactions."
  def cookie_name(state, secure \\ false) do
    prefix = if secure, do: "__Host-chat_overlay_oauth_", else: "chat_overlay_oauth_"
    prefix <> (digest(state) |> binary_part(0, 16) |> Base.encode16(case: :lower))
  end

  def bind(conn, state, provider, profile \\ nil) do
    with true <- Transport.oauth_allowed?(conn),
         {:ok, data} <- OAuth.verify_state(state),
         true <- data["provider"] == provider do
      conn = Plug.Conn.fetch_cookies(conn)

      grant = %{
        proof: data["auth_proof"],
        profile: authorization_snapshot(profile || Config.profile(data["handle"])),
        requester: digest(:erlang.term_to_binary(Transport.requester(conn))),
        session_hash: session_digest(conn)
      }

      binding = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      case GenServer.call(
             __MODULE__,
             {:register, digest(state), digest(binding), data["handle"], provider, grant}
           ) do
        :ok ->
          {:ok,
           Plug.Conn.put_resp_cookie(conn, cookie_name(state, Transport.secure?(conn)), binding,
             http_only: true,
             same_site: "Lax",
             secure: Transport.secure?(conn),
             path: "/",
             max_age: @ttl
           )}

        error ->
          error
      end
    else
      false -> {:error, :insecure_transport}
      _ -> {:error, :invalid_flow}
    end
  end

  def consume(conn, state, provider) when is_binary(state) do
    conn = Plug.Conn.fetch_cookies(conn)
    name = cookie_name(state, Transport.secure?(conn))

    with true <- Transport.oauth_allowed?(conn),
         binding when is_binary(binding) and byte_size(binding) == 43 <- conn.cookies[name],
         {:ok, %{"provider" => ^provider}} <- OAuth.verify_state(state),
         {:ok, grant} <-
           GenServer.call(__MODULE__, {:consume, digest(state), digest(binding), provider}) do
      {:ok,
       conn
       |> Plug.Conn.put_private(:oauth_grant, grant)
       |> Plug.Conn.delete_resp_cookie(name,
         http_only: true,
         same_site: "Lax",
         secure: Transport.secure?(conn),
         path: "/"
       )}
    else
      _ -> {:error, :invalid_flow}
    end
  end

  def consume(_, _, _), do: {:error, :invalid_flow}

  @doc "Evaluated by the serialized writer against the original authorization snapshot."
  def authorized?(conn, handle, profile) do
    snapshot = authorization_snapshot(profile)

    case conn.private[:oauth_grant] do
      %{profile: ^snapshot, proof: proof, session_hash: hash} ->
        case proof do
          "session" ->
            hash != nil and hash == session_digest(conn) and
              match?({:ok, _}, Session.fetch_session(conn)) and
              Session.authorize(conn, handle) == :ok

          "demo" ->
            Session.loopback?(conn) and Session.demo_profile?(handle)

          "capability_token" ->
            is_binary(profile["capability_token_hash"])

          "login" ->
            true

          nil ->
            true

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp authorization_snapshot(nil), do: nil

  defp authorization_snapshot(profile) do
    # Credential refresh and presentation are unrelated to ownership. Preserve
    # only the identity, account generation and capability used for authorization.
    accounts =
      Map.new(profile["linked_accounts"] || %{}, fn {provider, account} ->
        {provider, Map.take(account, ~w(user_id account_version))}
      end)

    sources =
      Enum.map(profile["sources"] || [], &Map.take(&1, ~w(platform mode user_id channel login)))

    profile
    |> Map.take(~w(handle capability_token_hash))
    |> Map.put("linked_accounts", accounts)
    |> Map.put("sources", sources)
  end

  defp session_digest(conn) do
    case Plug.Conn.fetch_cookies(conn).cookies[Session.cookie_name()] do
      token when is_binary(token) -> digest(token)
      _ -> nil
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value)
  defp now, do: System.monotonic_time(:second)
  defp privileged?(grant), do: grant.proof in ["session", "capability_token", "demo"]

  defp prune(entries, time),
    do: Map.reject(entries, fn {_, {_, _, _, expires, _}} -> expires <= time end)

  @impl true
  def init(_), do: {:ok, %{}}
  @impl true
  def handle_call({:register, state, binding, handle, provider, grant}, _, entries) do
    time = now()
    entries = prune(entries, time)
    privileged = privileged?(grant)

    count =
      Enum.count(entries, fn {_, {_, h, _, _, g}} ->
        h == handle and privileged?(g) == privileged and
          (privileged or g.requester == grant.requester)
      end)

    anonymous = Enum.count(entries, fn {_, {_, _, _, _, g}} -> not privileged?(g) end)

    cond do
      Map.has_key?(entries, state) ->
        {:reply, {:error, :duplicate_flow}, entries}

      map_size(entries) >= @limit or count >= if(privileged, do: @profile_limit, else: 4) or
          (not privileged and anonymous >= @anonymous_limit) ->
        {:reply, {:error, :flow_capacity}, entries}

      true ->
        {:reply, :ok, Map.put(entries, state, {binding, handle, provider, time + @ttl, grant})}
    end
  end

  def handle_call({:consume, state, binding, provider}, _, entries) do
    entries = prune(entries, now())

    case Map.get(entries, state) do
      {^binding, _, ^provider, _, grant} -> {:reply, {:ok, grant}, Map.delete(entries, state)}
      _ -> {:reply, {:error, :invalid_flow}, entries}
    end
  end
end
