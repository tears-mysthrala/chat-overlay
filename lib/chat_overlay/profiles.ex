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

  def init(_opts), do: {:ok, %{}}

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

  defp execute_action({:save_profile, profile, opts}), do: do_save_profile(profile, opts)
  defp execute_action({:delete, handle}), do: do_delete(handle)

  defp execute_action({:sync_youtube, handle, yt_source, yt_target, opts}),
    do: do_sync_youtube(handle, yt_source, yt_target, opts)

  defp execute_action({:update_linked_youtube, handle, yt_target}),
    do: do_update_linked_youtube(handle, yt_target)

  @doc "Lists all currently active profiles."
  def list do
    Enum.map(Config.profiles(), fn p ->
      %{
        "handle" => p["handle"],
        "platforms" => Enum.map(p["sources"], & &1["platform"]),
        "sources" => Enum.map(p["sources"], &format_source_summary/1),
        "overlay_platforms" => p["overlay_platforms"],
        "linked_youtube" => p["linked_youtube"],
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

                call_serialized({:sync_youtube, clean_handle, yt_source, stable_target, opts})

              {:error, :no_active_stream} ->
                {:error, :no_active_stream}

              {:error, {:no_active_stream, stable_target}} ->
                call_serialized({:update_linked_youtube, clean_handle, stable_target})
                {:error, :no_active_stream}

              error ->
                error
            end
        end
    end
  end

  defp do_sync_youtube(handle, yt_source, yt_target, opts) do
    current_profiles = Config.profiles()

    case Enum.find(current_profiles, &(&1["handle"] == handle)) do
      nil ->
        {:error, :not_found}

      existing ->
        existing_non_yt = Enum.reject(existing["sources"] || [], &(&1["platform"] == "youtube"))
        updated_sources = existing_non_yt ++ [yt_source]

        updated_profile =
          existing
          |> Map.put("sources", updated_sources)
          |> Map.put("linked_youtube", yt_target)

        do_save_profile(updated_profile, Keyword.put(opts, :replace, true))
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
  def delete(handle) when is_binary(handle) do
    call_serialized({:delete, handle})
  end

  def delete(_), do: {:error, :invalid_handle}

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

    final_profile =
      profile
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
        Application.put_env(:chat_overlay, :profiles, valid_profiles)

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

        persist_profiles(valid_profiles)
        {:ok, final_profile}

      error ->
        error
    end
  end

  defp do_delete(handle) do
    current_profiles = Config.profiles()

    case Enum.find(current_profiles, &(&1["handle"] == handle)) do
      nil ->
        {:error, :not_found}

      profile_to_delete ->
        remaining_profiles = Enum.reject(current_profiles, &(&1["handle"] == handle))

        with {:ok, valid_profiles} <- Config.validate(remaining_profiles) do
          Application.put_env(:chat_overlay, :profiles, valid_profiles)

          if Process.whereis(ChatOverlay.Stores) do
            _ = Supervisor.terminate_child(ChatOverlay.Stores, {:store, handle})
            _ = Supervisor.delete_child(ChatOverlay.Stores, {:store, handle})
          end

          cleanup_removed_sources(profile_to_delete["sources"] || [], valid_profiles)

          persist_profiles(valid_profiles)
          :ok
        end
    end
  end

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

  defp persist_profiles(profiles) do
    path =
      Application.get_env(:chat_overlay, :profiles_path) ||
        System.get_env("CHAT_CONFIG") ||
        "config/local-profiles.json"

    doc = %{"profiles" => profiles}

    try do
      case ChatOverlay.JSON.encode(doc) do
        json when is_binary(json) ->
          dir = Path.dirname(path)

          if File.dir?(dir) do
            tmp = Path.join(dir, ".profiles-#{:erlang.unique_integer([:positive])}.tmp")
            File.write!(tmp, json)
            File.rename!(tmp, path)
          end

          :ok

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end
end
