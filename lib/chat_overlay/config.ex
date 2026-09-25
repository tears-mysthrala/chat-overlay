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
  def key(s), do: {s["platform"], s["channel"], s["credential_env"]}
  def sources, do: profiles() |> Enum.flat_map(& &1["sources"]) |> Enum.uniq_by(&key/1)

  def handles(source),
    do:
      profiles()
      |> Enum.filter(fn p -> Enum.any?(p["sources"], &(key(&1) == key(source))) end)
      |> Enum.map(& &1["handle"])

  def handle?(x),
    do: is_binary(x) and byte_size(x) <= 40 and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,39}\z/, x)

  defp profile?(%{"handle" => handle, "sources" => sources} = p) when is_list(sources) do
    Enum.all?(Map.keys(p), &(&1 in ["handle", "sources", "overlay_platforms"])) and
      handle?(handle) and length(sources) in 1..3 and
      Enum.all?(sources, &source?/1) and overlay_platforms?(p) and
      unique?(sources, & &1["platform"])
  end

  defp profile?(_), do: false

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
      &(&1 in ~w(platform channel credential_env client_id user_id live_chat_id subscription_id moderation_subscription_id mode))
    ) and
      s["platform"] in ~w(twitch youtube kick) and Event.id?(s["channel"]) and
      s["mode"] in [nil, "demo"] and
      (s["mode"] == "demo" or (env?(s["credential_env"]) and details?(s)))
  end

  defp source?(_), do: false

  defp details?(%{"platform" => "twitch"} = s),
    do: numeric?(s["channel"]) and numeric?(s["user_id"]) and Event.id?(s["client_id"])

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
