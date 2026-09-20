defmodule ChatOverlay.Event do
  @moduledoc "Closed, size-bounded event schema shared by adapters and state."
  @platforms ~w(twitch youtube kick)
  @states ~w(connecting available offline degraded configuration_error)
  @types ~w(message delete_message delete_author clear_channel replace source_state)
  def valid?(e) when is_map(e) do
    Map.keys(e)
    |> Enum.all?(
      &(&1 in ~w(version event platform channel emission_session upstream_id received_at occurred_at payload))
    ) and
      e["version"] == 1 and e["platform"] in @platforms and e["event"] in @types and
      id?(e["channel"]) and optional_id?(e["emission_session"]) and
      id?(e["upstream_id"]) and timestamp?(e["received_at"]) and
      (is_nil(e["occurred_at"]) or timestamp?(e["occurred_at"])) and
      payload?(e["event"], e["payload"])
  end

  def valid?(_), do: false

  def new(platform, channel, type, id, payload, opts \\ []) do
    %{
      "version" => 1,
      "event" => type,
      "platform" => platform,
      "channel" => channel,
      "emission_session" => opts[:session],
      "upstream_id" => id,
      "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "occurred_at" => opts[:occurred_at],
      "payload" => payload
    }
  end

  def source_state(platform, channel, state) do
    new(
      platform,
      channel,
      "source_state",
      Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      %{"state" => state, "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()}
    )
  end

  def id?(x), do: text?(x, 256) and byte_size(x) > 0

  def text?(x, size),
    do:
      is_binary(x) and byte_size(x) <= size and String.valid?(x) and
        not String.contains?(x, <<0>>)

  def timestamp?(x) when is_binary(x) and byte_size(x) <= 40 do
    case DateTime.from_iso8601(x) do
      {:ok, _, 0} -> true
      _ -> false
    end
  end

  def timestamp?(_), do: false
  defp optional_id?(x), do: is_nil(x) or id?(x)
  defp payload?("message", p), do: message?(p)

  defp payload?("replace", %{"message_id" => id, "message" => message} = p),
    do: map_size(p) == 2 and id?(id) and message?(message) and message["message_id"] == id

  defp payload?("delete_message", %{"message_id" => id} = p), do: map_size(p) == 1 and id?(id)
  defp payload?("delete_author", %{"author_id" => id} = p), do: map_size(p) == 1 and id?(id)
  defp payload?("clear_channel", %{"scope" => "channel"} = p), do: map_size(p) == 1

  defp payload?("source_state", %{"state" => state, "observed_at" => at} = p),
    do: map_size(p) == 2 and state in @states and timestamp?(at)

  defp payload?(_, _), do: false

  defp message?(
         %{"message_id" => id, "author_id" => author, "author_display" => display, "text" => text} =
           p
       ),
       do:
         map_size(p) == 4 and id?(id) and id?(author) and text?(display, 256) and
           text?(text, 4096)

  defp message?(_), do: false
end
