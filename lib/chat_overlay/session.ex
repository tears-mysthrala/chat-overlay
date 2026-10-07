defmodule ChatOverlay.Session do
  @moduledoc """
  Session management and strict profile-level authorization for the Creator Dashboard.

  Provides encrypted dissociated sessions (HttpOnly, SameSite=Lax, Secure over HTTPS)
  using AES-256-GCM AEAD encryption with AAD separation, and enforces that authenticated
  creators may only access and mutate their own profile resources (SEC-12, SEC-14, ADR 0003).

  Also maintains zero-friction unauthenticated access for local loopback connections
  under demo mode (`config/demo.json`).
  """

  alias ChatOverlay.{Crypto, JSON, OAuth}

  @cookie_name "chat_overlay_session"
  @session_aad "chat_overlay_session"
  @default_max_age 604_800

  @doc """
  Returns the name of the session cookie.
  """
  @spec cookie_name() :: String.t()
  def cookie_name, do: @cookie_name

  @doc """
  Returns the encryption key used for session tokens.
  """
  @spec encryption_key() :: binary()
  def encryption_key, do: OAuth.encryption_key()

  @doc """
  Generates an encrypted, authenticated session token containing the creator's identity.
  Adds `created_at` and `expires_at` timestamps.
  """
  @spec create_token(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_token(payload, opts \\ []) when is_map(payload) do
    handle = payload["handle"] || payload[:handle]

    if is_nil(handle) or handle == "" do
      {:error, :invalid_handle}
    else
      provider = payload["provider"] || payload[:provider] || "direct"
      user_id = payload["user_id"] || payload[:user_id] || ""
      username = payload["username"] || payload[:username]
      account_version = payload["account_version"] || payload[:account_version]
      key = Keyword.get_lazy(opts, :key, &encryption_key/0)
      max_age = Keyword.get(opts, :max_age, @default_max_age)
      now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

      data =
        %{
          "handle" => to_string(handle),
          "provider" => to_string(provider),
          "user_id" => to_string(user_id),
          "created_at" => now,
          "expires_at" => now + max_age,
          "epoch" => epoch()
        }
        |> maybe_put("username", username)
        |> maybe_put("account_version", account_version)

      json = JSON.encode(data)
      Crypto.encrypt_aead(json, key, @session_aad)
    end
  end

  @doc """
  Revokes a session token so it cannot be used again across any device or client.
  """
  @spec revoke_token(String.t()) :: :ok
  def revoke_token(token, opts \\ [])

  def revoke_token(token, opts) when is_binary(token) do
    if Process.whereis(ChatOverlay.Profiles), do: ChatOverlay.Profiles.revoke_session(token, opts)
    :ok
  end

  def revoke_token(_, _), do: :ok

  def epoch do
    try do
      case :ets.lookup(:chat_overlay_revoked_sessions, :epoch) do
        [{:epoch, value}] -> value
        _ -> nil
      end
    rescue
      ArgumentError -> nil
    end
  end

  @doc """
  Checks if a session token has been revoked.
  """
  @spec revoked?(String.t()) :: boolean()
  def revoked?(token) when is_binary(token) do
    case :ets.info(:chat_overlay_revoked_sessions) do
      :undefined ->
        false

      _ ->
        hash = :crypto.hash(:sha256, token)
        :ets.member(:chat_overlay_revoked_sessions, hash)
    end
  end

  def revoked?(_), do: false

  @doc """
  Verifies and decrypts a session token. Validates integrity tag, AAD domain separation,
  and expiration timestamp.
  """
  @spec verify_token(String.t(), keyword()) ::
          {:ok, map()}
          | {:error,
             :session_expired
             | :revoked
             | :invalid_session_payload
             | :invalid_or_tampered_token
             | :invalid_token}
  def verify_token(token, opts \\ [])

  def verify_token("v1:" <> _ = token, opts) do
    if revoked?(token) do
      {:error, :revoked}
    else
      key = Keyword.get_lazy(opts, :key, &encryption_key/0)
      now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

      case Crypto.decrypt_aead(token, key, @session_aad) do
        {:ok, json} ->
          case JSON.decode(json) do
            {:ok, %{"handle" => handle, "expires_at" => expires_at} = session}
            when is_binary(handle) and byte_size(handle) > 0 and is_integer(expires_at) ->
              if expires_at > now and epoch() != nil and session["epoch"] == epoch() do
                {:ok, session}
              else
                {:error, :session_expired}
              end

            _ ->
              {:error, :invalid_session_payload}
          end

        {:error, _reason} ->
          {:error, :invalid_or_tampered_token}
      end
    end
  end

  def verify_token(_, _), do: {:error, :invalid_token}

  @doc """
  Extracts and verifies the session token from the `Plug.Conn` request cookies.
  """
  @spec fetch_session(Plug.Conn.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_session(%Plug.Conn{} = conn, opts \\ []) do
    conn = Plug.Conn.fetch_cookies(conn)

    case conn.cookies[@cookie_name] do
      token when is_binary(token) and byte_size(token) > 0 ->
        verify_token(token, opts)

      _ ->
        {:error, :no_session}
    end
  end

  @doc """
  Sets an encrypted session cookie on the `Plug.Conn` with HttpOnly, SameSite=Lax,
  and conditional Secure flags.
  """
  @spec put_session(Plug.Conn.t(), map(), keyword()) :: Plug.Conn.t()
  def put_session(%Plug.Conn{} = conn, session_data, opts \\ []) do
    case create_token(session_data, opts) do
      {:ok, token} ->
        secure =
          Keyword.get_lazy(opts, :secure, fn ->
            ChatOverlay.Transport.secure?(conn)
          end)

        max_age = Keyword.get(opts, :max_age, @default_max_age)

        Plug.Conn.put_resp_cookie(conn, @cookie_name, token,
          http_only: true,
          same_site: "Lax",
          path: "/",
          secure: secure,
          max_age: max_age
        )

      {:error, reason} ->
        raise ArgumentError, "Error al generar la cookie de sesión: #{inspect(reason)}"
    end
  end

  @doc """
  Clears the session cookie by setting `max-age=0` and invalidates the session token in the revocation table.
  """
  @spec delete_session(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def delete_session(%Plug.Conn{} = conn, opts \\ []) do
    conn = Plug.Conn.fetch_cookies(conn)

    case conn.cookies[@cookie_name] do
      token when is_binary(token) and byte_size(token) > 0 ->
        revoke_token(token, opts)

      _ ->
        :ok
    end

    secure =
      Keyword.get_lazy(opts, :secure, fn ->
        ChatOverlay.Transport.secure?(conn)
      end)

    Plug.Conn.delete_resp_cookie(conn, @cookie_name,
      http_only: true,
      same_site: "Lax",
      path: "/",
      secure: secure
    )
  end

  @doc """
  Determines whether the verified peer is direct local loopback, not a configured proxy.
  Forwarded client addresses and Host cannot grant the anonymous demo exception.
  """
  @spec loopback?(Plug.Conn.t()) :: boolean()
  def loopback?(%Plug.Conn{} = conn) do
    conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] and
      conn.remote_ip not in Application.get_env(:chat_overlay, :trusted_proxy_ips, [])
  end

  @doc """
  Checks if a handle or profile map corresponds to a demo profile.
  """
  @spec demo_profile?(String.t() | map()) :: boolean()
  def demo_profile?(%{"sources" => sources} = profile) when is_map(profile) do
    profile["handle"] == "demo" or
      (is_list(sources) and sources != [] and Enum.all?(sources, &(&1["mode"] == "demo")))
  end

  def demo_profile?(profile) when is_map(profile) do
    profile["handle"] == "demo" or demo_profile?(profile["handle"])
  end

  def demo_profile?(handle) when is_binary(handle) do
    handle == "demo" or
      case ChatOverlay.Config.profile(handle) do
        nil ->
          false

        profile ->
          sources = profile["sources"] || []
          is_list(sources) and sources != [] and Enum.all?(sources, &(&1["mode"] == "demo"))
      end
  end

  def demo_profile?(_), do: false

  @doc """
  Authorizes access to a target profile resource.

  Rules:
  1. If an active session is present, caller must match `handle` (SEC-14 strict authorization).
     Validates profile existence and linked account identity.
     Cross-profile access returns `{:error, :forbidden}`.
  2. If no session is present:
     - Local loopback connections under demo mode or querying unconfigured handles
       are allowed (`:ok`) for zero-friction quick start and testing.
     - Remote / non-loopback connections or production non-demo profiles return `{:error, :unauthorized}`.
  """
  @spec authorize(Plug.Conn.t(), String.t() | nil, keyword()) ::
          :ok | {:error, :unauthorized | :forbidden}
  def authorize(conn, handle, opts \\ [])

  def authorize(conn, handle, opts) do
    result = do_authorize(conn, handle, opts)
    if result == :ok, do: ChatOverlay.RequestScope.grant(handle)
    result
  end

  defp do_authorize(%Plug.Conn{} = conn, handle, opts) when is_binary(handle) do
    case fetch_session(conn, opts) do
      {:ok, session} ->
        session_handle = session["handle"]

        cond do
          session_handle != handle ->
            {:error, :forbidden}

          is_nil(ChatOverlay.Config.profile(handle)) ->
            {:error, :unauthorized}

          true ->
            profile = ChatOverlay.Config.profile(handle)
            provider = session["provider"]

            if provider in ["twitch", "youtube"] do
              linked = (profile["linked_accounts"] || %{})[provider]

              cond do
                is_nil(linked) ->
                  {:error, :unauthorized}

                session["user_id"] &&
                    to_string(linked["user_id"]) != to_string(session["user_id"]) ->
                  {:error, :unauthorized}

                session["account_version"] &&
                    to_string(linked["account_version"] || 1) !=
                      to_string(session["account_version"]) ->
                  {:error, :unauthorized}

                true ->
                  :ok
              end
            else
              :ok
            end
        end

      {:error, _reason} ->
        if loopback?(conn) and
             (demo_profile?(handle) or ChatOverlay.Config.profile(handle) == nil) do
          :ok
        else
          {:error, :unauthorized}
        end
    end
  end

  defp do_authorize(%Plug.Conn{}, _handle, _opts), do: {:error, :unauthorized}

  @doc """
  Authorizes creation of a new profile.
  Allowed if:
  - Authenticated user whose session handle matches the target handle, OR
  - Unauthenticated on local loopback where all sources in the payload are in demo mode.
  """
  @spec authorize_profile_creation(Plug.Conn.t(), map(), keyword()) ::
          :ok | {:error, :unauthorized | :forbidden}
  def authorize_profile_creation(conn, params, opts \\ [])

  def authorize_profile_creation(conn, params, opts) do
    result = do_authorize_profile_creation(conn, params, opts)
    if result == :ok, do: ChatOverlay.RequestScope.grant(params["handle"])
    result
  end

  defp do_authorize_profile_creation(%Plug.Conn{} = conn, params, opts) when is_map(params) do
    handle = params["handle"]

    case fetch_session(conn, opts) do
      {:ok, session} ->
        if session["handle"] == handle do
          :ok
        else
          {:error, :forbidden}
        end

      {:error, _reason} ->
        sources = params["sources"]

        demo_payload? =
          handle == "demo" or
            (is_list(sources) and sources != [] and Enum.all?(sources, &(&1["mode"] == "demo")))

        if loopback?(conn) and demo_payload? do
          :ok
        else
          {:error, :unauthorized}
        end
    end
  end

  defp do_authorize_profile_creation(%Plug.Conn{}, _, _), do: {:error, :unauthorized}

  @doc """
  Scopes a list of profiles according to the caller's authorization.
  - If authenticated: returns only profiles belonging to the session handle (SEC-12, SEC-14).
  - If unauthenticated on loopback: returns only demo profiles (zero-friction dev/demo).
  - If unauthenticated on remote network: returns `{:error, :unauthorized}`.
  """
  @spec scope_profiles(Plug.Conn.t(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, :unauthorized}
  def scope_profiles(%Plug.Conn{} = conn, profiles, opts \\ []) when is_list(profiles) do
    case fetch_session(conn, opts) do
      {:ok, session} ->
        session_handle = session["handle"]
        {:ok, Enum.filter(profiles, &(&1["handle"] == session_handle))}

      {:error, _reason} ->
        if loopback?(conn) do
          {:ok, Enum.filter(profiles, &demo_profile?/1)}
        else
          {:error, :unauthorized}
        end
    end
  end

  # Helpers

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, to_string(value))
end
