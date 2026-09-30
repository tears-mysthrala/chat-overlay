defmodule ChatOverlay.OAuth do
  @moduledoc """
  OAuth 2.0 PKCE and account linking management for Twitch and YouTube.
  Provides stateless authorization URL generation with AEAD-encrypted state,
  PKCE S256 verification, token exchange and secure token handling.

  Fulfills SEC-14, SEC-15 and Issue #23.
  """

  alias ChatOverlay.{Crypto, JSON}

  @providers %{
    "twitch" => %{
      auth_url: "https://id.twitch.tv/oauth2/authorize",
      token_url: "https://id.twitch.tv/oauth2/token",
      user_url: "https://api.twitch.tv/helix/users",
      default_scope: "user:read:email"
    },
    "youtube" => %{
      auth_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      user_url: "https://www.googleapis.com/oauth2/v3/userinfo",
      default_scope: "openid email https://www.googleapis.com/auth/youtube.readonly"
    }
  }

  @doc """
  Returns the 32-byte encryption key used for state and token encryption.
  """
  def encryption_key do
    System.get_env("CHAT_ENCRYPTION_KEY") ||
      Application.get_env(:chat_overlay, :encryption_key, "chat_overlay_secret_key_32_bytes!")
  end

  @doc """
  Retrieves client ID for the given provider from environment or configuration.
  """
  def client_id(provider) when provider in ["twitch", :twitch] do
    System.get_env("TWITCH_CLIENT_ID") ||
      Application.get_env(:chat_overlay, :twitch_client_id)
  end

  def client_id(provider) when provider in ["youtube", :youtube, "google", :google] do
    System.get_env("GOOGLE_CLIENT_ID") ||
      System.get_env("YOUTUBE_CLIENT_ID") ||
      Application.get_env(:chat_overlay, :google_client_id)
  end

  def client_id(_), do: nil

  @doc """
  Retrieves client secret for the given provider from environment or configuration.
  """
  def client_secret(provider) when provider in ["twitch", :twitch] do
    System.get_env("TWITCH_CLIENT_SECRET") ||
      Application.get_env(:chat_overlay, :twitch_client_secret)
  end

  def client_secret(provider) when provider in ["youtube", :youtube, "google", :google] do
    System.get_env("GOOGLE_CLIENT_SECRET") ||
      System.get_env("YOUTUBE_CLIENT_SECRET") ||
      Application.get_env(:chat_overlay, :google_client_secret)
  end

  def client_secret(_), do: nil

  @doc """
  Generates an authorization URL for OAuth 2.0 PKCE flow.
  """
  @spec authorize_url(String.t() | atom(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def authorize_url(provider, handle, redirect_uri, opts \\ []) do
    provider_str = to_string(provider)

    case Map.fetch(@providers, provider_str) do
      {:ok, config} ->
        case client_id(provider_str) do
          cid when is_binary(cid) and byte_size(cid) > 0 ->
            pkce = Crypto.generate_pkce()
            state = generate_state(handle, provider_str, pkce.verifier)

            params =
              %{
                "client_id" => cid,
                "redirect_uri" => redirect_uri,
                "response_type" => "code",
                "scope" => opts[:scope] || config.default_scope,
                "state" => state,
                "code_challenge" => pkce.challenge,
                "code_challenge_method" => pkce.method
              }
              |> maybe_add_google_opts(provider_str)

            query = URI.encode_query(params)
            {:ok, "#{config.auth_url}?#{query}"}

          _ ->
            {:error, {:unconfigured_client, provider_str}}
        end

      :error ->
        {:error, :unsupported_provider}
    end
  end

  @doc """
  Generates an encrypted state string containing handle, provider, PKCE verifier,
  timestamp and random nonce.
  """
  @spec generate_state(String.t(), String.t(), String.t()) :: String.t()
  def generate_state(handle, provider, verifier) do
    payload = %{
      "handle" => handle,
      "provider" => to_string(provider),
      "verifier" => verifier,
      "ts" => System.system_time(:second),
      "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }

    json = JSON.encode(payload)
    {:ok, encrypted_state} = Crypto.encrypt_aead(json, encryption_key(), "oauth_state")
    encrypted_state
  end

  @doc """
  Verifies and decrypts an OAuth state string. Validates timestamp expiration (default: 600s).
  """
  @spec verify_state(String.t(), integer()) ::
          {:ok, map()} | {:error, :expired | :invalid_state | :malformed_state}
  def verify_state(state, max_age_seconds \\ 600)

  def verify_state("v1:" <> _ = state, max_age_seconds) do
    case Crypto.decrypt_aead(state, encryption_key(), "oauth_state") do
      {:ok, json} ->
        case JSON.decode(json) do
          {:ok, %{"handle" => _h, "provider" => _p, "verifier" => _v, "ts" => ts} = data}
          when is_integer(ts) ->
            now = System.system_time(:second)

            if now - ts >= 0 and now - ts <= max_age_seconds do
              {:ok, data}
            else
              {:error, :expired}
            end

          _ ->
            {:error, :malformed_state}
        end

      _ ->
        {:error, :invalid_state}
    end
  end

  def verify_state(_, _), do: {:error, :invalid_state}

  @doc """
  Handles the OAuth callback, exchanging code for tokens and fetching identity.
  """
  @spec handle_callback(String.t() | atom(), String.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:error, :upstream_error, term()}
  def handle_callback(provider, code, state, redirect_uri, opts \\ []) do
    provider_str = to_string(provider)

    if err = opts[:error] do
      {:error, :upstream_error, err}
    else
      with {:ok, state_data} <- verify_state(state),
           true <- state_data["provider"] == provider_str || {:error, :provider_mismatch},
           config = Map.get(@providers, provider_str) || {:error, :unsupported_provider},
           {:ok, tokens} <-
             exchange_token(
               provider_str,
               code,
               state_data["verifier"],
               redirect_uri,
               config,
               opts
             ),
           {:ok, user_info} <- fetch_user_info(provider_str, tokens["access_token"], config, opts) do
        {:ok,
         %{
           handle: state_data["handle"],
           provider: provider_str,
           username: user_info.username,
           user_id: user_info.user_id,
           tokens: tokens
         }}
      end
    end
  end

  # Token exchange implementation

  defp exchange_token(provider, code, verifier, redirect_uri, config, opts) do
    if mock_client = opts[:http_client] do
      mock_client.(:post, config.token_url, [], %{
        code: code,
        verifier: verifier,
        redirect_uri: redirect_uri
      })
      |> parse_token_response()
    else
      cid = client_id(provider)
      csec = client_secret(provider)

      cond do
        is_nil(cid) or cid == "" ->
          {:error, {:unconfigured_client, provider}}

        is_nil(csec) or csec == "" ->
          {:error, {:unconfigured_client_secret, provider}}

        true ->
          body =
            URI.encode_query(%{
              "client_id" => cid,
              "client_secret" => csec,
              "code" => code,
              "code_verifier" => verifier,
              "grant_type" => "authorization_code",
              "redirect_uri" => redirect_uri
            })

          headers = [{"content-type", "application/x-www-form-urlencoded"}]
          uri = URI.parse(config.token_url)

          case ChatOverlay.Net.request(uri.host, "POST", uri.path, headers, body) do
            {:ok, status, _headers, resp_body} when status in 200..299 ->
              JSON.decode(resp_body)

            _other ->
              {:error, :token_exchange_failed}
          end
      end
    end
  end

  defp parse_token_response({:ok, 200, %{"access_token" => _} = tokens}), do: {:ok, tokens}

  defp parse_token_response({:ok, status, _}) when status >= 400,
    do: {:error, :token_exchange_failed}

  defp parse_token_response(_), do: {:error, :token_exchange_failed}

  # User info implementation

  defp fetch_user_info("twitch", access_token, config, opts) do
    if mock_client = opts[:http_client] do
      case mock_client.(:get, config.user_url, [], "") do
        {:ok, 200, %{"data" => [first | _]}} ->
          {:ok,
           %{
             username: first["display_name"] || first["login"],
             user_id: to_string(first["id"])
           }}

        _ ->
          {:error, :user_info_failed}
      end
    else
      headers = [
        {"authorization", "Bearer " <> access_token},
        {"client-id", client_id("twitch")}
      ]

      uri = URI.parse(config.user_url)

      case ChatOverlay.Net.request(uri.host, "GET", uri.path, headers, "") do
        {:ok, 200, _headers, body} ->
          with {:ok, %{"data" => [first | _]}} <- JSON.decode(body) do
            {:ok,
             %{
               username: first["display_name"] || first["login"],
               user_id: to_string(first["id"])
             }}
          else
            _ -> {:error, :user_info_failed}
          end

        _ ->
          {:error, :user_info_failed}
      end
    end
  end

  defp fetch_user_info("youtube", access_token, config, opts) do
    if mock_client = opts[:http_client] do
      case mock_client.(:get, config.user_url, [], "") do
        {:ok, 200, info} ->
          {:ok,
           %{
             username: info["name"] || info["email"] || "YouTube User",
             user_id: to_string(info["sub"] || info["id"] || "")
           }}

        _ ->
          {:error, :user_info_failed}
      end
    else
      headers = [{"authorization", "Bearer " <> access_token}]
      uri = URI.parse(config.user_url)

      case ChatOverlay.Net.request(uri.host, "GET", uri.path, headers, "") do
        {:ok, 200, _headers, body} ->
          with {:ok, info} <- JSON.decode(body) do
            {:ok,
             %{
               username: info["name"] || info["email"] || "YouTube User",
               user_id: to_string(info["sub"] || info["id"] || "")
             }}
          else
            _ -> {:error, :user_info_failed}
          end

        _ ->
          {:error, :user_info_failed}
      end
    end
  end

  defp maybe_add_google_opts(params, "youtube") do
    Map.merge(params, %{
      "access_type" => "offline",
      "prompt" => "consent"
    })
  end

  defp maybe_add_google_opts(params, _), do: params
end
