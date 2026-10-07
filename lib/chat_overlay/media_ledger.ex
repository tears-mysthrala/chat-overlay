defmodule ChatOverlay.MediaLedger do
  @moduledoc "Bounded inventory of reserved, active and retired R2 objects."
  @limit 128
  @profile_limit 12
  @fields ~w(handle key size category mime expires_at state)

  def valid?(objects) when is_list(objects) and length(objects) <= @limit do
    Enum.all?(objects, fn o ->
      is_map(o) and Enum.all?(@fields, &Map.has_key?(o, &1)) and
        Map.keys(o) -- (@fields ++ ~w(bucket job input_sha256 output_sha256 input_key)) == [] and
        valid_binding?(o) and
        ChatOverlay.Config.handle?(o["handle"]) and is_binary(o["key"]) and
        byte_size(o["key"]) <= 256 and String.starts_with?(o["key"], o["handle"] <> "/") and
        not String.contains?(o["key"], ["..", "\\", "?", "#", "\n", "\r"]) and
        o["category"] in ["audio", "image"] and is_binary(o["mime"]) and
        byte_size(o["mime"]) <= 64 and
        is_integer(o["size"]) and o["size"] in 1..2_097_152 and
        is_integer(o["expires_at"]) and o["expires_at"] > 0 and
        o["state"] in [
          "pending",
          "processing",
          "ready",
          "failed",
          "active",
          "retired",
          "deleting"
        ]
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

    object = Map.put(object, "bucket", "quarantine")

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
                 o["size"] == item["size"] and o["state"] in ["ready", "active"] and
                 o["bucket"] == "public" and is_binary(o["output_sha256"])
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

  defp valid_binding?(o) do
    (is_nil(o["bucket"]) or o["bucket"] in ["quarantine", "public"]) and
      (is_nil(o["job"]) or (is_binary(o["job"]) and Regex.match?(~r/\A[0-9a-f]{32}\z/, o["job"]))) and
      Enum.all?(~w(input_sha256 output_sha256), fn field ->
        is_nil(o[field]) or (is_binary(o[field]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, o[field]))
      end) and
      (is_nil(o["input_key"]) or (is_binary(o["input_key"]) and byte_size(o["input_key"]) <= 256))
  end

  def media_items(profile) do
    (profile["media"] || %{})
    |> Map.values()
    |> Enum.filter(fn item ->
      is_map(item) and item["source"] == "r2" and is_integer(item["size"]) and item["size"] >= 0
    end)
  end
end
