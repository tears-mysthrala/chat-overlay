defmodule ChatOverlay.JSON do
  @moduledoc "Bounded JSON boundary. Keys remain binaries; decoding never creates atoms."
  @max_bytes 262_144
  def decode(data, limit \\ @max_bytes)

  def decode(data, limit)
      when limit in [@max_bytes, 2_097_152] and is_binary(data) and byte_size(data) <= limit do
    # Bound nesting before the runtime decoder allocates nested containers.
    with true <- depth?(data, 0, false, false) do
      try do
        {:ok, JSON.decode!(data)}
      rescue
        _ -> {:error, :invalid_json}
      end
    else
      _ -> {:error, :invalid_json}
    end
  end

  def decode(_, _), do: {:error, :too_large}
  def encode(value), do: JSON.encode!(value)
  defp depth?(<<>>, depth, quoted, _), do: depth == 0 and not quoted
  defp depth?(_, depth, _, _) when depth > 16 or depth < 0, do: false
  defp depth?(<<_, rest::binary>>, d, true, true), do: depth?(rest, d, true, false)
  defp depth?(<<92, rest::binary>>, d, true, false), do: depth?(rest, d, true, true)
  defp depth?(<<34, rest::binary>>, d, q, false), do: depth?(rest, d, not q, false)

  defp depth?(<<c, rest::binary>>, d, false, false) when c in [91, 123],
    do: depth?(rest, d + 1, false, false)

  defp depth?(<<c, rest::binary>>, d, false, false) when c in [93, 125],
    do: depth?(rest, d - 1, false, false)

  defp depth?(<<_, rest::binary>>, d, q, e), do: depth?(rest, d, q, e)
end
