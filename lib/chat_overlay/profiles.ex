defmodule ChatOverlay.Profiles do
  @moduledoc "Dynamic profile and source lifecycle management."
  use GenServer
  alias ChatOverlay.{Config, Resolver, Source, Store}

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

  @doc "Lists all currently active profiles."
  def list do
    Enum.map(Config.profiles(), fn p ->
      %{
        "handle" => p["handle"],
        "platforms" => Enum.map(p["sources"], & &1["platform"]),
        "sources" => Enum.map(p["sources"], &format_source_summary/1),
        "overlay_platforms" => p["overlay_platforms"],
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
    platform = opts[:platform] || detect_platform(target)

    case platform do
      "twitch" ->
        with {:ok, info} <- Resolver.resolve_twitch(target, opts) do
          source = %{
            "platform" => "twitch",
            "channel" => info["channel"],
            "user_id" => info["user_id"],
            "client_id" => info["client_id"],
            "credential_env" => "CHAT_TWITCH_TOKEN"
          }

          {:ok, source, info["login"]}
        end

      "youtube" ->
        with {:ok, info} <- Resolver.resolve_youtube(target, opts) do
          source = %{
            "platform" => "youtube",
            "channel" => info["channel"],
            "live_chat_id" => info["live_chat_id"],
            "credential_env" => "CHAT_YOUTUBE_TOKEN"
          }

          suggested_handle = slugify(info["title"] || "")
          {:ok, source, suggested_handle}
        end

      _ ->
        case Resolver.resolve_twitch(target, opts) do
          {:ok, info} ->
            source = %{
              "platform" => "twitch",
              "channel" => info["channel"],
              "user_id" => info["user_id"],
              "client_id" => info["client_id"],
              "credential_env" => "CHAT_TWITCH_TOKEN"
            }

            {:ok, source, info["login"]}

          _ ->
            case Resolver.resolve_youtube(target, opts) do
              {:ok, info} ->
                source = %{
                  "platform" => "youtube",
                  "channel" => info["channel"],
                  "live_chat_id" => info["live_chat_id"],
                  "credential_env" => "CHAT_YOUTUBE_TOKEN"
                }

                suggested_handle = slugify(info["title"] || "")
                {:ok, source, suggested_handle}

              error ->
                error
            end
        end
    end
  end

  @doc "Creates or updates a profile in runtime, hot-starting supervisors."
  def create_or_update(params, opts \\ []) when is_map(params) do
    handle = params["handle"] || params[:handle]
    target = params["target"] || params[:target] || params["input"] || params[:input]
    raw_sources = params["sources"] || params[:sources]

    with {:ok, sources, suggested_handle} <- resolve_sources(target, raw_sources, opts),
         {:ok, clean_handle} <- determine_handle(handle, suggested_handle, sources) do
      candidate_profile = %{
        "handle" => clean_handle,
        "sources" => sources
      }

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

    final_profile =
      profile
      |> Map.put("sources", final_sources)

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

            {:error, {:already_started, _pid}} ->
              _ = Supervisor.terminate_child(ChatOverlay.Stores, {:store, clean_handle})
              _ = Supervisor.delete_child(ChatOverlay.Stores, {:store, clean_handle})
              {:ok, _} = Supervisor.start_child(ChatOverlay.Stores, store_spec)
              :ok

            {:error, :already_present} ->
              _ = Supervisor.delete_child(ChatOverlay.Stores, {:store, clean_handle})
              {:ok, _} = Supervisor.start_child(ChatOverlay.Stores, store_spec)
              :ok

            _ ->
              :ok
          end
        end

        # Synchronize Sources supervisor
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

          remaining_source_keys =
            valid_profiles
            |> Enum.flat_map(& &1["sources"])
            |> Enum.map(&Config.key/1)
            |> MapSet.new()

          if Process.whereis(ChatOverlay.Sources) do
            Enum.each(profile_to_delete["sources"], fn src ->
              key = Config.key(src)

              unless MapSet.member?(remaining_source_keys, key) do
                _ = Supervisor.terminate_child(ChatOverlay.Sources, {:source, key})
                _ = Supervisor.delete_child(ChatOverlay.Sources, {:source, key})
              end
            end)
          end

          persist_profiles(valid_profiles)
          :ok
        end
    end
  end

  defp resolve_sources(target, raw_sources, opts) do
    cond do
      is_binary(target) and byte_size(String.trim(target)) > 0 ->
        case resolve_target(target, opts) do
          {:ok, source, suggested} ->
            {:ok, [source], suggested}

          error ->
            error
        end

      is_list(raw_sources) and raw_sources != [] ->
        results =
          Enum.reduce_while(raw_sources, {:ok, []}, fn
            %{"platform" => _, "channel" => _} = src, {:ok, acc} ->
              {:cont, {:ok, [src | acc]}}

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
          {:ok, sources} -> {:ok, Enum.reverse(sources), nil}
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
    path = System.get_env("CHAT_CONFIG") || "config/local-profiles.json"
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
