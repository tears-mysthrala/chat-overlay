defmodule ChatOverlay.MediaLedger do
  @moduledoc "Bounded inventory of reserved, active and retired R2 objects."
  @limit 128
  @profile_limit 12
  @fields ~w(handle key size category mime expires_at state)

  def valid?(objects) when is_list(objects) and length(objects) <= @limit do
    Enum.all?(objects, fn o ->
      is_map(o) and Enum.sort(Map.keys(o)) == Enum.sort(@fields) and
        ChatOverlay.Config.handle?(o["handle"]) and is_binary(o["key"]) and
        byte_size(o["key"]) <= 256 and String.starts_with?(o["key"], o["handle"] <> "/") and
        not String.contains?(o["key"], ["..", "\\", "?", "#", "\n", "\r"]) and
        o["category"] in ["audio", "image"] and is_binary(o["mime"]) and
        byte_size(o["mime"]) <= 64 and
        is_integer(o["size"]) and o["size"] in 1..2_097_152 and
        is_integer(o["expires_at"]) and o["expires_at"] > 0 and
        o["state"] in ["pending", "active", "retired", "deleting"]
    end) and Enum.uniq_by(objects, & &1["key"]) == objects
  end

  def valid?(_), do: false

  def reserve(objects, profile, upload, now) do
    handle = profile["handle"]
    key = handle <> "/" <> upload.key

    object = %{
      "handle" => handle,
      "key" => key,
      "size" => upload.size,
      "category" => to_string(upload.category),
      "mime" => upload.mime,
      "expires_at" => now + 300,
      "state" => "pending"
    }

    cond do
      profile["can_upload"] != true ->
        {:error, :uploads_not_allowed}

      not tracked?(objects, profile) ->
        {:error, :media_inventory_required}

      length(objects) >= @limit ->
        {:error, :upload_reservations_full}

      Enum.count(objects, &(&1["handle"] == handle)) >= @profile_limit ->
        {:error, :profile_upload_reservations_full}

      not valid?(objects ++ [object]) ->
        {:error, :invalid_parameters}

      total_bytes(objects, profile) + upload.size > (profile["storage_quota_bytes"] || 10_485_760) ->
        {:error, :quota_exceeded}

      true ->
        {:ok, objects ++ [object], object}
    end
  end

  def tracked?(objects, profile) do
    Enum.all?(Map.values(profile["media"] || %{}), fn item ->
      item["source"] != "r2" or
        Enum.any?(objects, fn o ->
          o["handle"] == profile["handle"] and o["key"] == item["key"] and
            o["size"] == item["size"] and o["state"] == "active"
        end)
    end)
  end

  def total_bytes(objects, profile) do
    own = Enum.filter(objects, &(&1["handle"] == profile["handle"]))
    keys = MapSet.new(Enum.map(own, & &1["key"]))
    legacy = profile |> media_items() |> Enum.reject(&MapSet.member?(keys, &1["key"]))
    Enum.sum(Enum.map(own ++ legacy, & &1["size"]))
  end

  # Rechecked inside Profiles' serialized mutation, after HTTP validation.
  def activatable?(objects, profile, media) do
    tracked?(objects, profile) and
      Enum.all?(media, fn {slot, item} ->
        item["source"] != "r2" or item == (profile["media"] || %{})[slot] or
          (profile["can_upload"] == true and
             Enum.any?(objects, fn o ->
               o["key"] == item["key"] and o["handle"] == profile["handle"] and
                 o["size"] == item["size"] and o["state"] in ["pending", "active"] and
                 o["expires_at"] > System.system_time(:second)
             end))
      end)
  end

  def transition(objects, handle, media) do
    keys = MapSet.new(Enum.map(media_items(%{"media" => media}), & &1["key"]))

    Enum.map(objects, fn object ->
      if object["handle"] == handle do
        cond do
          MapSet.member?(keys, object["key"]) -> Map.put(object, "state", "active")
          object["state"] == "active" -> Map.put(object, "state", "retired")
          true -> object
        end
      else
        object
      end
    end)
  end

  def retire(objects, handle) do
    Enum.map(objects, fn o ->
      if o["handle"] == handle, do: Map.put(o, "state", "retired"), else: o
    end)
  end

  def due?(object, now), do: object["state"] != "active" and object["expires_at"] + 30 <= now

  def media_items(profile) do
    (profile["media"] || %{})
    |> Map.values()
    |> Enum.filter(fn item ->
      is_map(item) and item["source"] == "r2" and is_integer(item["size"]) and item["size"] >= 0
    end)
  end
end
