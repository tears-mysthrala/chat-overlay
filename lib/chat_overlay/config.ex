defmodule ChatOverlay.Config do
  @moduledoc "Operator-only JSON configuration. Unknown options fail closed. No secrets in errors."
  alias ChatOverlay.Event

  def load!(path) do
    with {:ok, %{size: size}} when size <= 65_536 <- File.stat(path),
         {:ok, body} <- File.read(path),
         {:ok, %{"profiles" => profiles} = doc} <- ChatOverlay.JSON.decode(body),
         true <- map_size(doc) == 1,
         {:ok, result} <- validate(profiles) do
      result
    else
      _ -> raise "Invalid overlay configuration (content redacted)"
    end
  end

  def validate(profiles) when is_list(profiles) and length(profiles) <= 10 do
    if Enum.all?(profiles, &profile?/1) and unique?(profiles, & &1["handle"]) and
         compatible?(profiles) and twitch_capacity?(profiles) do
      {:ok, profiles}
    else
      {:error, :invalid_configuration}
    end
  end

  def validate(_), do: {:error, :invalid_configuration}
  def profiles, do: Application.get_env(:chat_overlay, :profiles, [])
  def profile(handle), do: Enum.find(profiles(), &(&1["handle"] == handle))

  def key(%{"platform" => "youtube"} = s),
    do: {s["platform"], s["channel"], s["live_chat_id"], s["credential_env"]}

  def key(s), do: {s["platform"], s["channel"], s["credential_env"]}
  def sources, do: profiles() |> Enum.flat_map(& &1["sources"]) |> Enum.uniq_by(&key/1)

  def handles(source),
    do:
      profiles()
      |> Enum.filter(fn p -> Enum.any?(p["sources"], &(key(&1) == key(source))) end)
      |> Enum.map(& &1["handle"])

  def handle?(x),
    do: is_binary(x) and byte_size(x) <= 40 and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,39}\z/, x)

  @f2_profile_keys ~w(handle sources overlay_platforms linked_youtube capability_token_hash media can_upload storage_quota_bytes storage_used_bytes)

  defp profile?(%{"handle" => handle, "sources" => sources} = p) when is_list(sources) do
    Enum.all?(Map.keys(p), &(&1 in @f2_profile_keys)) and
      handle?(handle) and length(sources) in 1..3 and
      Enum.all?(sources, &source?/1) and overlay_platforms?(p) and
      linked_youtube?(p) and
      capability_token_hash?(p) and
      media?(p) and
      upload_quota?(p) and
      unique?(sources, & &1["platform"])
  end

  defp profile?(_), do: false

  defp capability_token_hash?(p) do
    case p["capability_token_hash"] do
      nil ->
        true

      hash when is_binary(hash) ->
        byte_size(hash) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)

      _ ->
        false
    end
  end

  defp media?(p) do
    case p["media"] do
      nil ->
        true

      m when is_map(m) ->
        Enum.all?(Map.keys(m), &(&1 in ["alert_sound", "alert_image"])) and
          Enum.all?(Map.values(m), &media_item?/1)

      _ ->
        false
    end
  end

  defp media_item?(item) when is_map(item) do
    url = item["url"]
    source = item["source"]

    is_binary(url) and byte_size(url) in 1..2048 and
      String.starts_with?(url, "https://") and
      (is_nil(source) or source in ["r2", "external"])
  end

  defp media_item?(_), do: false

  defp upload_quota?(p) do
    can_upload = p["can_upload"]
    quota = p["storage_quota_bytes"]
    used = p["storage_used_bytes"]

    (is_nil(can_upload) or is_boolean(can_upload)) and
      (is_nil(quota) or (is_integer(quota) and quota >= 0 and quota <= 1_073_741_824)) and
      (is_nil(used) or (is_integer(used) and used >= 0))
  end

  defp linked_youtube?(p) do
    case p["linked_youtube"] do
      nil ->
        true

      url when is_binary(url) ->
        byte_size(url) in 1..2048 and String.starts_with?(url, ["http://", "https://", "@", "UC"])

      _ ->
        false
    end
  end

  defp overlay_platforms?(p) do
    case p["overlay_platforms"] do
      nil ->
        true

      list when is_list(list) ->
        list != [] and length(list) <= 3 and
          Enum.all?(list, &(&1 in Enum.map(p["sources"], fn s -> s["platform"] end)))

      _ ->
        false
    end
  end

  defp source?(s) when is_map(s) do
    Enum.all?(
      Map.keys(s),
      &(&1 in ~w(platform channel credential_env client_id user_id live_chat_id subscription_id moderation_subscription_id mode login))
    ) and
      s["platform"] in ~w(twitch youtube kick) and Event.id?(s["channel"]) and
      s["mode"] in [nil, "demo"] and
      (s["mode"] == "demo" or (env?(s["credential_env"]) and details?(s)))
  end

  defp source?(_), do: false

  defp details?(%{"platform" => "twitch"} = s),
    do:
      numeric?(s["channel"]) and numeric?(s["user_id"]) and Event.id?(s["client_id"]) and
        (is_nil(s["login"]) or (is_binary(s["login"]) and Event.id?(s["login"])))

  defp details?(%{"platform" => "youtube"} = s), do: Event.id?(s["live_chat_id"])

  defp details?(%{"platform" => "kick"} = s),
    do:
      numeric?(s["channel"]) and Event.id?(s["subscription_id"]) and
        (is_nil(s["moderation_subscription_id"]) or Event.id?(s["moderation_subscription_id"]))

  defp env?(x),
    do: is_binary(x) and byte_size(x) <= 80 and Regex.match?(~r/\ACHAT_[A-Z0-9_]+\z/, x)

  defp numeric?(x), do: is_binary(x) and byte_size(x) <= 32 and Regex.match?(~r/\A[0-9]+\z/, x)
  defp unique?(xs, f), do: length(xs) == length(Enum.uniq_by(xs, f))

  defp compatible?(profiles) do
    sources = Enum.flat_map(profiles, & &1["sources"])
    # Same upstream/auth context must never resolve to conflicting options.
    sources
    |> Enum.group_by(&key/1)
    |> Enum.all?(fn {_, group} -> length(Enum.uniq(group)) == 1 end)
  end

  defp twitch_capacity?(profiles) do
    profiles
    |> Enum.flat_map(& &1["sources"])
    |> Enum.uniq_by(&key/1)
    |> Enum.filter(&(&1["platform"] == "twitch" and &1["mode"] != "demo"))
    |> Enum.group_by(&{&1["client_id"], &1["user_id"]})
    |> Enum.all?(fn {_, sources} -> length(sources) <= 3 end)
  end
end
