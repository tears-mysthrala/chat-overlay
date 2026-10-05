defmodule ChatOverlay.Profiles do
  @moduledoc "Dynamic profile and source lifecycle management."
  use GenServer
  alias ChatOverlay.{Config, Resolver, Source, Store}

  @platform_credentials %{
    "twitch" => "CHAT_TWITCH_TOKEN",
    "youtube" => "CHAT_YOUTUBE_TOKEN"
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def init(_opts) do
    if :ets.info(:chat_overlay_revoked_sessions) == :undefined do
      :ets.new(:chat_overlay_revoked_sessions, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])
    end

    {:ok, %{}}
  end

  def handle_call(action, _from, state) do
    result = execute_action(action)
    {:reply, result, state}
  end

  defp call_serialized(action) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        execute_action(action)

      pid ->
        GenServer.call(pid, action, 30_000)
    end
  end

  def reserve_media_upload(handle, upload), do: call_serialized({:reserve_media, handle, upload})

  def cleanup_media(key) do
    # Persist an irreversible claim before remote I/O; never block the shared writer.
    with {:ok, object} <- call_serialized({:claim_cleanup_media, key}),
         :ok <- ChatOverlay.Media.delete_object(key) do
      call_serialized({:finish_cleanup_media, object})
    else
      :absent -> :ok
      error -> error
    end
  end

  def media_objects, do: Application.get_env(:chat_overlay, :media_objects, [])

  defp execute_action({:reserve_media, handle, upload}) do
    with profile when is_map(profile) <- Config.profile(handle),
         {:ok, objects, object} <-
           ChatOverlay.MediaLedger.reserve(
             media_objects(),
             profile,
             upload,
             System.system_time(:second)
           ),
         :ok <- persist_profiles(Config.profiles(), objects) do
      Application.put_env(:chat_overlay, :media_objects, objects)
      {:ok, object}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp execute_action({:claim_cleanup_media, key}) do
    now = System.system_time(:second)
    objects = media_objects()

    case Enum.find(objects, &(&1["key"] == key)) do
      nil ->
        :absent

      object ->
        if ChatOverlay.MediaLedger.due?(object, now) do
          claimed = Map.put(object, "state", "deleting")
          updated = Enum.map(objects, fn o -> if o["key"] == key, do: claimed, else: o end)

          with :ok <- persist_profiles(Config.profiles(), updated) do
            Application.put_env(:chat_overlay, :media_objects, updated)
            {:ok, claimed}
          end
        else
          {:error, :object_not_retired}
        end
    end
  end

  defp execute_action({:finish_cleanup_media, claimed}) do
    objects = media_objects()

    if claimed in objects do
      remaining = Enum.reject(objects, &(&1 == claimed))

      with :ok <- persist_profiles(Config.profiles(), remaining) do
        Application.put_env(:chat_overlay, :media_objects, remaining)
        :ok
      end
    else
      {:error, :cleanup_state_changed}
    end
  end

  defp execute_action({:save_profile, profile, opts}), do: do_save_profile(profile, opts)
  defp execute_action({:delete, handle}), do: do_delete(handle, [])
  defp execute_action({:delete, handle, opts}), do: do_delete(handle, opts)

  defp execute_action({:sync_youtube, handle, yt_source, yt_target, resolved_for, opts}),
    do: do_sync_youtube(handle, yt_source, yt_target, resolved_for, opts)

  defp execute_action({:sync_youtube_offline, handle, yt_target, resolved_for, opts}),
    do: do_sync_youtube_offline(handle, yt_target, resolved_for, opts)

  defp execute_action({:update_linked_youtube, handle, yt_target}),
    do: do_update_linked_youtube(handle, yt_target)

  defp execute_action({:regenerate_capability_token, handle}),
    do: do_regenerate_capability_token(handle)

  defp execute_action({:update_media, handle, media_attrs}),
    do: do_update_media(handle, media_attrs, [])

  defp execute_action({:update_media, handle, media_attrs, opts}),
    do: do_update_media(handle, media_attrs, opts)

  defp execute_action({:update_upload_quota, handle, delta}),
    do: do_update_upload_quota(handle, delta)

  defp execute_action({:link_account, handle, provider, account_data, tokens}),
    do: do_link_account(handle, provider, account_data, tokens)

  defp execute_action({:update_tokens, handle, provider, new_tokens}),
    do: do_update_tokens(handle, provider, new_tokens, [])

  defp execute_action({:update_tokens, handle, provider, new_tokens, opts}),
    do: do_update_tokens(handle, provider, new_tokens, opts)

  defp execute_action({:mark_reauth_required, handle, provider, reason, opts}),
    do: do_mark_reauth_required(handle, provider, reason, opts)

  defp execute_action({:mark_reauth_required, handle, provider, reason}),
    do: do_mark_reauth_required(handle, provider, reason, [])

  defp execute_action({:unlink_account, handle, provider}),
    do: do_unlink_account(handle, provider)

  @doc "Lists all currently active profiles."
  def list do
    Enum.map(Config.profiles(), fn p ->
      %{
        "handle" => p["handle"],
        "platforms" => Enum.map(p["sources"], & &1["platform"]),
        "sources" => Enum.map(p["sources"], &format_source_summary/1),
        "overlay_platforms" => p["overlay_platforms"],
        "linked_youtube" => p["linked_youtube"],
        "has_capability_token" => not is_nil(p["capability_token_hash"]),
        "media" => p["media"] || %{},
        "can_upload" => p["can_upload"] || false,
        "storage_quota_bytes" => p["storage_quota_bytes"] || 10_485_760,
        "storage_used_bytes" => p["storage_used_bytes"] || 0,
        "storage_pending_bytes" =>
          max(
            0,
            ChatOverlay.MediaLedger.total_bytes(media_objects(), p) -
              (p["storage_used_bytes"] || 0)
          ),
        "linked_accounts" => format_linked_accounts_summary(p["linked_accounts"]),
        "reader_url" => "/reader/#{p["handle"]}",
        "overlay_url" => "/overlay/#{p["handle"]}"
      }
    end)
  end

  @doc "Finds a profile summary by handle."
  def get(handle) when is_binary(handle) do
    Enum.find(list(), &(&1["handle"] == handle))
  end

  def get(_), do: nil

  @doc "Generates and persists a new 32-byte capability token for the given profile handle."
  def regenerate_capability_token(handle) when is_binary(handle) do
    call_serialized({:regenerate_capability_token, handle})
  end

  def regenerate_capability_token(_), do: {:error, :invalid_handle}

  @doc "Verifies whether a capability token matches the profile's token hash. If no hash is set, allows access for backwards compatibility."
  def verify_capability_token(handle, token) when is_binary(handle) do
    case Config.profile(handle) do
      nil ->
        {:error, :not_found}

      profile ->
        case profile["capability_token_hash"] do
          nil ->
            {:ok, profile}

          "" ->
            {:ok, profile}

          hash when is_binary(hash) and is_binary(token) ->
            if ChatOverlay.Crypto.verify_token(token, hash) do
              {:ok, profile}
            else
              {:error, :unauthorized}
            end

          _ ->
            {:error, :unauthorized}
        end
    end
  end

  def verify_capability_token(_, _), do: {:error, :unauthorized}

  @doc "Updates the media settings (alert audio/images) for a profile."
  def update_media(handle, media_attrs, opts \\ [])

  def update_media(handle, media_attrs, opts)
      when is_binary(handle) and is_map(media_attrs) and is_list(opts) do
    call_serialized({:update_media, handle, media_attrs, opts})
  end

  def update_media(_, _, _), do: {:error, :invalid_params}

  @doc "Updates the storage_used_bytes for a profile by a delta amount."
  def update_upload_quota(handle, bytes_used_delta)
      when is_binary(handle) and is_integer(bytes_used_delta) do
    call_serialized({:update_upload_quota, handle, bytes_used_delta})
  end

  def update_upload_quota(_, _), do: {:error, :invalid_params}

  @doc "Links an external platform account (Twitch, YouTube) with encrypted tokens."
  def link_account(handle, provider, account_data, tokens)
      when is_binary(handle) and is_map(account_data) and is_map(tokens) do
    call_serialized({:link_account, handle, to_string(provider), account_data, tokens})
  end

  def link_account(_, _, _, _), do: {:error, :invalid_params}

  @doc "Unlinks an external platform account, removing stored encrypted credentials."
  def unlink_account(handle, provider) when is_binary(handle) do
    call_serialized({:unlink_account, handle, to_string(provider)})
  end

  def unlink_account(_, _), do: {:error, :invalid_params}

  @doc "Updates tokens for a linked platform account, merging with existing tokens and preserving refresh_token if not rotated."
  def update_tokens(handle, provider, new_tokens, opts \\ [])

  def update_tokens(handle, provider, new_tokens, opts)
      when is_binary(handle) and is_map(new_tokens) and is_list(opts) do
    call_serialized({:update_tokens, handle, to_string(provider), new_tokens, opts})
  end

  def update_tokens(_, _, _, _), do: {:error, :invalid_params}

  @doc "Marks a linked platform account as requiring re-authentication due to token expiration or revocation."
  def mark_account_reauth_required(handle, provider, reason \\ :invalid_grant, opts \\ [])

  def mark_account_reauth_required(handle, provider, reason, opts)
      when is_binary(handle) and is_list(opts) do
    call_serialized({:mark_reauth_required, handle, to_string(provider), to_string(reason), opts})
  end

  def mark_account_reauth_required(handle, provider, reason, opts)
      when is_binary(handle) and is_nil(opts) do
    mark_account_reauth_required(handle, provider, reason, [])
  end

  def mark_account_reauth_required(_, _, _, _), do: {:error, :invalid_params}

  @doc "Retrieves linked account metadata and decrypted tokens for an authorized internal component."
  def get_linked_account_auth(handle, provider) when is_binary(handle) do
    case Config.profile(handle) do
      nil ->
        {:error, :not_found}

      profile ->
        provider_str = to_string(provider)
        linked = (profile["linked_accounts"] || %{})[provider_str]

        if is_map(linked) and is_binary(linked["encrypted_tokens"]) do
          key = ChatOverlay.OAuth.encryption_key()

          case ChatOverlay.Crypto.decrypt_aead(
                 linked["encrypted_tokens"],
                 key,
                 "token:#{handle}:#{provider_str}"
               ) do
            {:ok, json_str} ->
              case ChatOverlay.JSON.decode(json_str) do
                {:ok, tokens} when is_map(tokens) ->
                  tokens_with_exp = Map.put_new(tokens, "expires_at", linked["expires_at"])

                  {:ok,
                   %{
                     account: Map.delete(linked, "encrypted_tokens"),
                     tokens: tokens_with_exp,
                     account_version: linked["account_version"] || 1
                   }}

                err ->
                  err
              end

            error ->
              error
          end
        else
          {:error, :not_linked}
        end
    end
  end

  def get_linked_account_auth(_, _), do: {:error, :invalid_params}

  @doc "Retrieves and decrypts stored tokens for an authorized internal component."
  def get_linked_account_tokens(handle, provider) when is_binary(handle) do
    case get_linked_account_auth(handle, provider) do
      {:ok, %{tokens: tokens}} -> {:ok, tokens}
      error -> error
    end
  end

  def get_linked_account_tokens(_, _), do: {:error, :invalid_params}

  @doc "Resolves a user-provided target into a source configuration."
  def resolve_target(target, opts \\ []) when is_binary(target) do
    with {:ok, sources, suggested, meta} <- resolve_target_with_meta(target, opts) do
      if opts[:with_meta] do
        {:ok, sources, suggested, meta}
      else
        {:ok, hd(sources), suggested}
      end
    end
  end

  @doc "Resolves a user-provided target returning all discovered sources and metadata."
  def resolve_target_with_meta(target, opts \\ []) when is_binary(target) do
    platform = opts[:platform] || detect_platform(target)

    case platform do
      "twitch" ->
        resolve_twitch_target(target, opts)

      "youtube" ->
        resolve_youtube_target(target, opts)

      _ ->
        case resolve_twitch_target(target, opts) do
          {:ok, _, _, _} = res -> res
          _ -> resolve_youtube_target(target, opts)
        end
    end
  end

  defp resolve_twitch_target(target, opts) do
    with {:ok, info} <- Resolver.resolve_twitch(target, opts) do
      twitch_source = %{
        "platform" => "twitch",
        "channel" => info["channel"],
        "login" => info["login"],
        "user_id" => info["user_id"],
        "client_id" => info["client_id"],
        "credential_env" => @platform_credentials["twitch"]
      }

      handle = info["login"]
      auto_discover? = Keyword.get(opts, :auto_discover_youtube, true)

      {sources, meta} =
        if auto_discover? do
          case Resolver.discover_twitch_youtube(info["login"], description: info["description"]) do
            {:ok, yt_url} ->
              case Resolver.resolve_youtube(yt_url, opts) do
                {:ok, yt_info} ->
                  stable_yt_url =
                    if is_binary(yt_info["channel"]) and
                         String.contains?(yt_url, ["watch?", "youtu.be", "/live/"]) do
                      "https://www.youtube.com/channel/#{yt_info["channel"]}"
                    else
                      yt_url
                    end

                  yt_source = %{
                    "platform" => "youtube",
                    "channel" => yt_info["channel"],
                    "live_chat_id" => yt_info["live_chat_id"],
                    "credential_env" => @platform_credentials["youtube"]
                  }

                  {[twitch_source, yt_source],
                   %{"linked_youtube" => stable_yt_url, "youtube_live" => true}}

                {:error, :no_active_stream} ->
                  {[twitch_source], %{"linked_youtube" => yt_url, "youtube_live" => false}}

                {:error, {:no_active_stream, stable_channel_url}} ->
                  {[twitch_source],
                   %{"linked_youtube" => stable_channel_url, "youtube_live" => false}}

                {:error, reason} ->
                  {[twitch_source],
                   %{
                     "linked_youtube" => yt_url,
                     "youtube_live" => false,
                     "youtube_error" => reason
                   }}
              end

            _ ->
              {[twitch_source], %{}}
          end
        else
          {[twitch_source], %{}}
        end

      {:ok, sources, handle, meta}
    end
  end

  defp resolve_youtube_target(target, opts) do
    with {:ok, info} <- Resolver.resolve_youtube(target, opts) do
      source = %{
        "platform" => "youtube",
        "channel" => info["channel"],
        "live_chat_id" => info["live_chat_id"],
        "credential_env" => @platform_credentials["youtube"]
      }

      suggested_handle = slugify(info["handle"] || info["channel"] || info["title"] || "")
      {:ok, [source], suggested_handle, %{}}
    end
  end

  @doc "Creates or updates a profile in runtime, hot-starting supervisors."
  def create_or_update(params, opts \\ []) when is_map(params) do
    handle = params["handle"] || params[:handle]
    target = params["target"] || params[:target] || params["input"] || params[:input]
    raw_sources = params["sources"] || params[:sources]

    with {:ok, sources, suggested_handle, meta} <- resolve_sources(target, raw_sources, opts),
         {:ok, clean_handle} <- determine_handle(handle, suggested_handle, sources) do
      candidate_profile =
        %{
          "handle" => clean_handle,
          "sources" => sources
        }
        |> maybe_put_linked_youtube(
          params["linked_youtube"] || params[:linked_youtube] || meta["linked_youtube"]
        )

      candidate_profile =
        case params["overlay_platforms"] || params[:overlay_platforms] do
          list when is_list(list) and list != [] ->
            Map.put(candidate_profile, "overlay_platforms", list)

          _ ->
            candidate_profile
        end

      call_serialized({:save_profile, candidate_profile, opts})
    end
  end

  @doc "Synchronizes the linked YouTube live stream for an existing profile."
  def sync_youtube(handle, opts \\ []) when is_binary(handle) do
    clean_handle = slugify(handle)

    case Config.profile(clean_handle) do
      nil ->
        {:error, :not_found}

      profile ->
        target =
          profile["linked_youtube"] ||
            find_youtube_target_from_sources(profile["sources"], clean_handle)

        case target do
          nil ->
            {:error, :no_linked_youtube}

          yt_target ->
            case Resolver.resolve_youtube(yt_target, opts) do
              {:ok, yt_info} ->
                stable_target =
                  if yt_info["handle"],
                    do: "https://www.youtube.com/@" <> yt_info["handle"],
                    else: "https://www.youtube.com/channel/" <> yt_info["channel"]

                yt_source = %{
                  "platform" => "youtube",
                  "channel" => yt_info["channel"],
                  "live_chat_id" => yt_info["live_chat_id"],
                  "credential_env" => @platform_credentials["youtube"]
                }

                call_serialized(
                  {:sync_youtube, clean_handle, yt_source, stable_target, yt_target, opts}
                )

              {:error, :no_active_stream} ->
                call_serialized({:sync_youtube_offline, clean_handle, nil, yt_target, opts})
                {:error, :no_active_stream}

              {:error, {:no_active_stream, stable_target}} ->
                call_serialized(
                  {:sync_youtube_offline, clean_handle, stable_target, yt_target, opts}
                )

                {:error, :no_active_stream}

              error ->
                error
            end
        end
    end
  end

  defp do_sync_youtube(handle, yt_source, yt_target, resolved_for, opts) do
    current_profiles = Config.profiles()

    case Enum.find(current_profiles, &(&1["handle"] == handle)) do
      nil ->
        {:error, :not_found}

      existing ->
        current_linked = existing["linked_youtube"]

        if current_linked != nil and current_linked != resolved_for and
             current_linked != yt_target do
          {:error, :target_changed_concurrently}
        else
          existing_non_yt = Enum.reject(existing["sources"] || [], &(&1["platform"] == "youtube"))
          updated_sources = existing_non_yt ++ [yt_source]

          updated_overlay_platforms =
            case existing["overlay_platforms"] do
              list when is_list(list) ->
                Enum.uniq(list ++ ["youtube"])

              other ->
                other
            end

          updated_profile =
            existing
            |> Map.put("sources", updated_sources)
            |> Map.put("linked_youtube", yt_target)
            |> Map.put("overlay_platforms", updated_overlay_platforms)

          do_save_profile(updated_profile, Keyword.put(opts, :replace, true))
        end
    end
  end

  defp do_sync_youtube_offline(handle, yt_target, resolved_for, opts) do
    current_profiles = Config.profiles()

    case Enum.find(current_profiles, &(&1["handle"] == handle)) do
      nil ->
        {:error, :not_found}

      existing ->
        current_linked = existing["linked_youtube"]

        if current_linked != nil and current_linked != resolved_for and
             current_linked != yt_target do
          {:error, :target_changed_concurrently}
        else
          existing_non_yt = Enum.reject(existing["sources"] || [], &(&1["platform"] == "youtube"))
          remaining_platforms = Enum.map(existing_non_yt, & &1["platform"])

          updated_overlay_platforms =
            case existing["overlay_platforms"] do
              list when is_list(list) ->
                filtered = Enum.filter(list, &(&1 in remaining_platforms))
                if filtered == [], do: remaining_platforms, else: filtered

              other ->
                other
            end

          updated_profile =
            existing
            |> Map.put("sources", existing_non_yt)
            |> Map.put("overlay_platforms", updated_overlay_platforms)

          updated_profile =
            if yt_target,
              do: Map.put(updated_profile, "linked_youtube", yt_target),
              else: updated_profile

          do_save_profile(updated_profile, Keyword.put(opts, :replace, true))
        end
    end
  end

  defp do_update_linked_youtube(handle, yt_target) do
    current_profiles = Config.profiles()

    case Enum.find(current_profiles, &(&1["handle"] == handle)) do
      nil ->
        {:error, :not_found}

      existing ->
        if existing["linked_youtube"] != yt_target do
          updated = Map.put(existing, "linked_youtube", yt_target)
          do_save_profile(updated, replace: true)
        else
          :ok
        end
    end
  end

  defp find_youtube_target_from_sources(sources, fallback_handle) do
    twitch = Enum.find(sources, &(&1["platform"] == "twitch"))

    target_name =
      cond do
        twitch && twitch["login"] -> twitch["login"]
        twitch && twitch["channel"] -> twitch["channel"]
        true -> fallback_handle
      end

    opts =
      if twitch do
        opts = []

        opts =
          if twitch["client_id"],
            do: Keyword.put(opts, :client_id, twitch["client_id"]),
            else: opts

        opts =
          if twitch["user_id"], do: Keyword.put(opts, :user_id, twitch["user_id"]), else: opts

        opts =
          if twitch["credential_env"],
            do: Keyword.put(opts, :token, System.get_env(twitch["credential_env"])),
            else: opts

        opts
      else
        []
      end

    case Resolver.discover_twitch_youtube(target_name, opts) do
      {:ok, url} -> url
      _ -> nil
    end
  end

  defp maybe_put_linked_youtube(profile, url) when is_binary(url) and byte_size(url) > 0 do
    Map.put(profile, "linked_youtube", url)
  end

  defp maybe_put_linked_youtube(profile, _), do: profile

  @doc "Deletes a profile in runtime, stopping supervisors and removing unused sources."
  def delete(handle, opts \\ [])

  def delete(handle, opts) when is_binary(handle) and is_list(opts) do
    call_serialized({:delete, handle, opts})
  end

  def delete(_, _), do: {:error, :invalid_handle}

  defp do_save_profile(profile, opts) do
    clean_handle = profile["handle"]
    current_profiles = Config.profiles()
    existing = Enum.find(current_profiles, &(&1["handle"] == clean_handle))

    final_sources =
      cond do
        opts[:replace] == true or is_nil(existing) ->
          profile["sources"]

        true ->
          new_platforms = Enum.map(profile["sources"], & &1["platform"])

          Enum.reject(existing["sources"], &(&1["platform"] in new_platforms)) ++
            profile["sources"]
      end

    removed_sources =
      if existing do
        (existing["sources"] || []) -- final_sources
      else
        []
      end

    linked_yt = profile["linked_youtube"] || (existing && existing["linked_youtube"])

    base_profile =
      if existing && opts[:replace] != true do
        Map.merge(existing, profile)
      else
        profile
      end

    final_profile =
      base_profile
      |> Map.put("sources", final_sources)
      |> then(fn p ->
        if linked_yt, do: Map.put(p, "linked_youtube", linked_yt), else: p
      end)

    updated_profiles =
      if existing do
        Enum.map(current_profiles, fn p ->
          if p["handle"] == clean_handle, do: final_profile, else: p
        end)
      else
        current_profiles ++ [final_profile]
      end

    case Config.validate(updated_profiles) do
      {:ok, valid_profiles} ->
        objects = Keyword.get(opts, :media_objects, media_objects())

        case persist_profiles(valid_profiles, objects) do
          :ok ->
            Application.put_env(:chat_overlay, :media_objects, objects)
            Application.put_env(:chat_overlay, :profiles, valid_profiles)
            sync_profile_supervisors(final_profile, clean_handle, removed_sources, valid_profiles)
            {:ok, final_profile}

          {:error, _} = error ->
            error
        end

      error ->
        error
    end
  end

  defp sync_profile_supervisors(final_profile, clean_handle, removed_sources, valid_profiles) do
    # Synchronize Store supervisor
    if Process.whereis(ChatOverlay.Stores) do
      store_spec = Store.child_spec(final_profile)

      case Supervisor.start_child(ChatOverlay.Stores, store_spec) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, pid}} ->
          Store.update_sources(pid, final_profile["sources"])
          :ok

        {:error, :already_present} ->
          case Supervisor.restart_child(ChatOverlay.Stores, {:store, clean_handle}) do
            {:ok, pid} -> Store.update_sources(pid, final_profile["sources"])
            _ -> :ok
          end

        _ ->
          :ok
      end
    end

    # Synchronize Sources supervisor: start new sources
    if Process.whereis(ChatOverlay.Sources) do
      Enum.each(final_profile["sources"], fn src ->
        source_spec = Source.child_spec(src)

        case Supervisor.start_child(ChatOverlay.Sources, source_spec) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, :already_present} ->
            _ = Supervisor.restart_child(ChatOverlay.Sources, source_spec.id)
            :ok

          _ ->
            :ok
        end
      end)
    end

    # Clean up any orphaned source workers that were removed from this profile
    cleanup_removed_sources(removed_sources, valid_profiles)
  end

  defp do_delete(handle, opts) do
    current_profiles = Config.profiles()

    case Enum.find(current_profiles, &(&1["handle"] == handle)) do
      nil ->
        {:error, :not_found}

      profile_to_delete ->
        remaining_profiles = Enum.reject(current_profiles, &(&1["handle"] == handle))

        objects = ChatOverlay.MediaLedger.retire(media_objects(), handle)

        with true <-
               ChatOverlay.MediaLedger.tracked?(media_objects(), profile_to_delete) ||
                 {:error, :media_inventory_required},
             {:ok, valid_profiles} <- Config.validate(remaining_profiles),
             :ok <- persist_profiles(valid_profiles, objects) do
          Application.put_env(:chat_overlay, :media_objects, objects)
          Application.put_env(:chat_overlay, :profiles, valid_profiles)
          ChatOverlay.Stream.disconnect_viewers(handle, :profile_deleted)

          if Process.whereis(ChatOverlay.Stores) do
            _ = Supervisor.terminate_child(ChatOverlay.Stores, {:store, handle})
            _ = Supervisor.delete_child(ChatOverlay.Stores, {:store, handle})
          end

          cleanup_removed_sources(profile_to_delete["sources"] || [], valid_profiles)

          invalidate_tokens(handle, "twitch")
          invalidate_tokens(handle, "youtube")

          if opts[:with_removed_keys] do
            media = profile_to_delete["media"] || %{}

            r2_keys =
              Enum.flat_map(["alert_sound", "alert_image"], fn k ->
                item = media[k]

                if is_map(item) and item["source"] == "r2" and is_binary(item["key"]) and
                     byte_size(item["key"]) > 0 do
                  [item["key"]]
                else
                  []
                end
              end)

            {:ok, r2_keys}
          else
            :ok
          end
        end
    end
  end

  defp do_regenerate_capability_token(handle) do
    current_profiles = Config.profiles()

    case Enum.find(current_profiles, &(&1["handle"] == handle)) do
      nil ->
        {:error, :not_found}

      existing ->
        token = ChatOverlay.Crypto.generate_capability_token()
        hash = ChatOverlay.Crypto.hash_token(token)
        updated_profile = Map.put(existing, "capability_token_hash", hash)

        case do_save_profile(updated_profile, replace: true) do
          {:ok, saved} ->
            ChatOverlay.Stream.disconnect_viewers(handle, :token_revoked)
            {:ok, token, saved}

          error ->
            error
        end
    end
  end

  defp do_update_media(handle, media_attrs, opts) do
    current_profiles = Config.profiles()

    case Enum.find(current_profiles, &(&1["handle"] == handle)) do
      nil ->
        {:error, :not_found}

      existing ->
        current_media = existing["media"] || %{}
        merged_media = Map.merge(current_media, media_attrs)

        cleaned_media =
          Enum.reduce(merged_media, %{}, fn {k, v}, acc ->
            if is_map(v) and is_binary(v["url"]) and byte_size(v["url"]) > 0 do
              Map.put(acc, k, v)
            else
              acc
            end
          end)

        # Detect orphaned/replaced R2 keys
        removed_r2_keys =
          Enum.reduce(["alert_sound", "alert_image"], [], fn key, acc ->
            old_item = current_media[key]
            new_item = cleaned_media[key]

            old_key =
              if is_map(old_item) and old_item["source"] == "r2" and
                   is_binary(old_item["key"]) and byte_size(old_item["key"]) > 0 do
                old_item["key"]
              else
                nil
              end

            new_key =
              if is_map(new_item) and new_item["source"] == "r2" and
                   is_binary(new_item["key"]) and byte_size(new_item["key"]) > 0 do
                new_item["key"]
              else
                nil
              end

            if old_key && old_key != new_key do
              [old_key | acc]
            else
              acc
            end
          end)

        # Calculate new storage used across active R2 media
        new_storage_used =
          Enum.reduce(cleaned_media, 0, fn {_k, v}, sum ->
            if is_map(v) and v["source"] == "r2" do
              sum + max(0, v["size"] || 0)
            else
              sum
            end
          end)

        quota = existing["storage_quota_bytes"] || ChatOverlay.Media.default_quota()

        cond do
          opts[:require_reservation] == true and
              not ChatOverlay.MediaLedger.activatable?(media_objects(), existing, cleaned_media) ->
            {:error, :invalid_upload_token}

          new_storage_used > quota ->
            {:error, :quota_exceeded}

          true ->
            updated_profile =
              existing
              |> Map.put("media", cleaned_media)
              |> Map.put("storage_used_bytes", new_storage_used)

            objects = ChatOverlay.MediaLedger.transition(media_objects(), handle, cleaned_media)

            case do_save_profile(updated_profile, replace: true, media_objects: objects) do
              {:ok, saved} ->
                if opts[:with_removed_keys] do
                  {:ok, saved, Enum.reverse(removed_r2_keys)}
                else
                  {:ok, saved}
                end

              error ->
                error
            end
        end
    end
  end

  defp do_update_upload_quota(handle, delta) do
    current_profiles = Config.profiles()

    case Enum.find(current_profiles, &(&1["handle"] == handle)) do
      nil ->
        {:error, :not_found}

      existing ->
        current_used = existing["storage_used_bytes"] || 0
        new_used = max(0, current_used + delta)
        updated_profile = Map.put(existing, "storage_used_bytes", new_used)
        do_save_profile(updated_profile, replace: true)
    end
  end

  defp do_link_account(handle, provider, account_data, tokens) do
    current_profiles = Config.profiles()

    case Enum.find(current_profiles, &(&1["handle"] == handle)) do
      nil ->
        {:error, :not_found}

      existing ->
        provider_str = to_string(provider)
        key = ChatOverlay.OAuth.encryption_key()

        with {:ok, enc_tokens} <-
               ChatOverlay.Crypto.encrypt_aead(
                 ChatOverlay.JSON.encode(tokens),
                 key,
                 "token:#{handle}:#{provider_str}"
               ) do
          expires_in = tokens["expires_in"] || tokens[:expires_in] || 3600
          now = System.system_time(:second)

          existing_linked = existing["linked_accounts"] || %{}
          prev_account = existing_linked[provider_str]

          prev_version =
            if is_map(prev_account), do: prev_account["account_version"] || 0, else: 0

          new_version = max(prev_version + 1, System.unique_integer([:positive, :monotonic]))

          entry = %{
            "linked" => true,
            "provider" => provider_str,
            "account_version" => new_version,
            "user_id" => to_string(account_data[:user_id] || account_data["user_id"] || ""),
            "username" =>
              to_string(
                account_data[:username] || account_data["username"] || account_data[:title] ||
                  account_data["title"] || ""
              ),
            "linked_at" => now,
            "expires_at" => now + expires_in,
            "encrypted_tokens" => enc_tokens,
            "status" => "active"
          }

          updated_linked = Map.put(existing_linked, provider_str, entry)
          updated_profile = Map.put(existing, "linked_accounts", updated_linked)

          case do_save_profile(updated_profile, replace: true, require_persistence: true) do
            {:ok, _} = res ->
              invalidate_tokens(handle, provider_str)
              res

            err ->
              err
          end
        end
    end
  end

  defp do_unlink_account(handle, provider) do
    current_profiles = Config.profiles()

    case Enum.find(current_profiles, &(&1["handle"] == handle)) do
      nil ->
        {:error, :not_found}

      existing ->
        provider_str = to_string(provider)
        existing_linked = existing["linked_accounts"] || %{}
        updated_linked = Map.delete(existing_linked, provider_str)
        updated_profile = Map.put(existing, "linked_accounts", updated_linked)

        case do_save_profile(updated_profile, replace: true, require_persistence: true) do
          {:ok, _} = res ->
            invalidate_tokens(handle, provider_str)
            res

          err ->
            err
        end
    end
  end

  defp do_update_tokens(handle, provider, new_tokens, opts) do
    current_profiles = Config.profiles()

    case Enum.find(current_profiles, &(&1["handle"] == handle)) do
      nil ->
        {:error, :not_found}

      existing ->
        provider_str = to_string(provider)
        existing_linked = existing["linked_accounts"] || %{}

        case Map.fetch(existing_linked, provider_str) do
          {:ok, current_account} when is_map(current_account) ->
            expected_version = opts[:expected_version]
            current_version = current_account["account_version"] || 1

            if expected_version && current_version != expected_version do
              {:error, :stale_binding}
            else
              key = ChatOverlay.OAuth.encryption_key()
              old_enc_tokens = current_account["encrypted_tokens"]
              normalized_tokens = for {k, v} <- new_tokens, into: %{}, do: {to_string(k), v}

              with {:ok, merged_tokens} <-
                     merge_refresh_token(
                       normalized_tokens,
                       old_enc_tokens,
                       handle,
                       provider_str,
                       key
                     ),
                   {:ok, enc_tokens} <-
                     ChatOverlay.Crypto.encrypt_aead(
                       ChatOverlay.JSON.encode(merged_tokens),
                       key,
                       "token:#{handle}:#{provider_str}"
                     ) do
                expires_in = merged_tokens["expires_in"] || 3600
                now = System.system_time(:second)

                updated_account =
                  current_account
                  |> Map.put("encrypted_tokens", enc_tokens)
                  |> Map.put("expires_at", now + expires_in)
                  |> Map.put("status", "active")
                  |> Map.delete("last_error")

                updated_linked = Map.put(existing_linked, provider_str, updated_account)
                updated_profile = Map.put(existing, "linked_accounts", updated_linked)
                do_save_profile(updated_profile, replace: true, require_persistence: true)
              end
            end

          _ ->
            {:error, :not_linked}
        end
    end
  end

  defp merge_refresh_token(new_tokens, old_enc_tokens, handle, provider_str, key) do
    new_refresh = new_tokens["refresh_token"]

    if is_binary(new_refresh) and byte_size(new_refresh) > 0 do
      {:ok, new_tokens}
    else
      if is_binary(old_enc_tokens) do
        case ChatOverlay.Crypto.decrypt_aead(
               old_enc_tokens,
               key,
               "token:#{handle}:#{provider_str}"
             ) do
          {:ok, json_str} ->
            case ChatOverlay.JSON.decode(json_str) do
              {:ok, prev_tokens} when is_map(prev_tokens) ->
                old_refresh = prev_tokens["refresh_token"] || prev_tokens[:refresh_token]

                if is_binary(old_refresh) and byte_size(old_refresh) > 0 do
                  {:ok, Map.put(new_tokens, "refresh_token", old_refresh)}
                else
                  {:ok, new_tokens}
                end

              _ ->
                {:ok, new_tokens}
            end

          _ ->
            {:ok, new_tokens}
        end
      else
        {:ok, new_tokens}
      end
    end
  end

  defp do_mark_reauth_required(handle, provider, reason, opts) do
    current_profiles = Config.profiles()

    case Enum.find(current_profiles, &(&1["handle"] == handle)) do
      nil ->
        {:error, :not_found}

      existing ->
        provider_str = to_string(provider)
        existing_linked = existing["linked_accounts"] || %{}

        case Map.fetch(existing_linked, provider_str) do
          {:ok, current_account} when is_map(current_account) ->
            updated_account =
              current_account
              |> Map.put("status", "reauth_required")
              |> Map.put("last_error", to_string(reason))

            updated_linked = Map.put(existing_linked, provider_str, updated_account)
            updated_profile = Map.put(existing, "linked_accounts", updated_linked)

            result = do_save_profile(updated_profile, replace: true)

            # Revoked/rotated upstream credentials must remain unusable even when disk is
            # unavailable. This explicit safety state is not a successful durable write.
            if match?({:error, _}, result) do
              profiles =
                Enum.map(current_profiles, fn p ->
                  if p["handle"] == handle, do: updated_profile, else: p
                end)

              Application.put_env(:chat_overlay, :profiles, profiles)

              if Keyword.get(opts, :invalidate_cache, true),
                do: invalidate_tokens(handle, provider_str)
            end

            case result do
              {:ok, _} = res ->
                if Keyword.get(opts, :invalidate_cache, true) do
                  invalidate_tokens(handle, provider_str)
                end

                res

              err ->
                err
            end

          _ ->
            {:error, :not_linked}
        end
    end
  end

  defp invalidate_tokens(handle, provider) do
    if is_pid(Process.whereis(ChatOverlay.Tokens)) do
      ChatOverlay.Tokens.invalidate(handle, provider)
    end
  end

  defp format_linked_accounts_summary(linked) when is_map(linked) do
    Enum.reduce(linked, %{}, fn {provider, data}, acc ->
      if is_map(data) do
        sanitized =
          data
          |> Map.delete("encrypted_tokens")
          |> Map.put_new("linked", true)

        Map.put(acc, provider, sanitized)
      else
        acc
      end
    end)
  end

  defp format_linked_accounts_summary(_), do: %{}

  defp cleanup_removed_sources(removed_sources, valid_profiles) do
    if is_pid(Process.whereis(ChatOverlay.Sources)) and removed_sources != [] do
      remaining_keys =
        valid_profiles
        |> Enum.flat_map(& &1["sources"])
        |> Enum.map(&Config.key/1)
        |> MapSet.new()

      Enum.each(removed_sources, fn src ->
        key = Config.key(src)

        unless MapSet.member?(remaining_keys, key) do
          _ = Supervisor.terminate_child(ChatOverlay.Sources, {:source, key})
          _ = Supervisor.delete_child(ChatOverlay.Sources, {:source, key})
        end
      end)
    end
  end

  defp resolve_sources(target, raw_sources, opts) do
    cond do
      is_binary(target) and byte_size(String.trim(target)) > 0 ->
        target_opts = Keyword.put(opts, :with_meta, true)

        case resolve_target(target, target_opts) do
          {:ok, sources, suggested, meta} ->
            {:ok, List.wrap(sources), suggested, meta}

          {:ok, sources, suggested} ->
            {:ok, List.wrap(sources), suggested, %{}}

          error ->
            error
        end

      is_list(raw_sources) and raw_sources != [] ->
        results =
          Enum.reduce_while(raw_sources, {:ok, []}, fn
            %{"platform" => plat, "channel" => _} = src, {:ok, acc} ->
              cleaned_src =
                if src["mode"] == "demo" do
                  Map.delete(src, "credential_env")
                else
                  case Map.fetch(@platform_credentials, plat) do
                    {:ok, env_name} ->
                      Map.put(src, "credential_env", env_name)

                    :error ->
                      :unsupported
                  end
                end

              case cleaned_src do
                :unsupported -> {:halt, {:error, :invalid_source_spec}}
                valid_src -> {:cont, {:ok, [valid_src | acc]}}
              end

            %{"target" => tgt} = item, {:ok, acc} ->
              item_opts = Keyword.merge(opts, platform: item["platform"])

              case resolve_target(tgt, item_opts) do
                {:ok, src, _} -> {:cont, {:ok, [src | acc]}}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            _, _ ->
              {:halt, {:error, :invalid_source_spec}}
          end)

        case results do
          {:ok, sources} -> {:ok, Enum.reverse(sources), nil, %{}}
          error -> error
        end

      true ->
        {:error, :missing_target_or_sources}
    end
  end

  defp determine_handle(handle, suggested_handle, sources) do
    cond do
      is_binary(handle) and byte_size(String.trim(handle)) > 0 ->
        clean = handle |> String.trim() |> String.downcase()
        if Config.handle?(clean), do: {:ok, clean}, else: {:error, :invalid_handle}

      is_binary(suggested_handle) and byte_size(suggested_handle) > 0 ->
        clean = suggested_handle |> String.trim() |> slugify()
        if Config.handle?(clean), do: {:ok, clean}, else: {:error, :invalid_handle}

      sources != [] ->
        first = hd(sources)
        clean = (first["channel"] || "stream") |> String.downcase() |> slugify()
        if Config.handle?(clean), do: {:ok, clean}, else: {:error, :invalid_handle}

      true ->
        {:error, :handle_required}
    end
  end

  defp detect_platform(target) do
    cond do
      String.contains?(target, "twitch.tv") ->
        "twitch"

      String.contains?(target, ["youtube.com", "youtu.be"]) or
          (String.starts_with?(target, "UC") and byte_size(target) == 24) ->
        "youtube"

      true ->
        nil
    end
  end

  def slugify(nil), do: ""

  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.replace(~r/^[^a-z0-9]+/, "")
    |> String.replace(~r/-+$/, "")
    |> String.slice(0, 40)
  end

  defp format_source_summary(source) do
    case source["platform"] do
      "twitch" ->
        %{
          "platform" => "twitch",
          "channel" => source["channel"],
          "mode" => source["mode"]
        }

      "youtube" ->
        %{
          "platform" => "youtube",
          "channel" => source["channel"],
          "live_chat_id" => source["live_chat_id"],
          "mode" => source["mode"]
        }

      "kick" ->
        %{
          "platform" => "kick",
          "channel" => source["channel"],
          "mode" => source["mode"]
        }

      other ->
        %{"platform" => other}
    end
  end

  defp persist_profiles(profiles, objects) do
    path =
      Application.get_env(:chat_overlay, :profiles_path) ||
        System.get_env("CHAT_CONFIG") ||
        "config/local-profiles.json"

    ChatOverlay.ProfileStorage.write(path, profiles, objects || media_objects())
  end
end
