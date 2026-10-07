defmodule ChatOverlay.MediaPreview do
  @moduledoc "Manual preview of active, normalized local objects; no upstream events."

  def payload(profile, objects) do
    media = profile["media"] || %{}

    result =
      Enum.reduce_while(
        [
          {"alert_image", "image", "image/png", "image_url"},
          {"alert_sound", "audio", "audio/wav", "audio_url"}
        ],
        %{"version" => 1},
        fn {field, category, mime, output}, acc ->
          case media[field] do
            nil ->
              {:cont, acc}

            %{"source" => "local", "key" => key} = item ->
              object =
                Enum.find(
                  objects,
                  &(&1["key"] == key and &1["handle"] == profile["handle"] and
                      &1["state"] == "active" and &1["bucket"] == "public" and
                      &1["backend"] == "local" and &1["category"] == category and
                      &1["mime"] == mime and &1["size"] == item["size"] and
                      is_binary(&1["output_sha256"]))
                )

              case {object, ChatOverlay.Media.public_url(key)} do
                {object, {:ok, url}} when is_map(object) ->
                  path = URI.parse(url).path

                  extension = if category == "image", do: "png", else: "wav"

                  pattern =
                    "\\A" <>
                      Regex.escape(profile["handle"]) <>
                      "/validated/[a-f0-9]{32}/" <>
                      Regex.escape(object["output_sha256"]) <> "\\." <> extension <> "\\z"

                  if item["url"] == url and is_binary(path) and
                       String.starts_with?(path, "/media/local/") and
                       Regex.match?(Regex.compile!(pattern), key),
                     do: {:cont, Map.put(acc, output, path)},
                     else: {:halt, :rejected}

                _ ->
                  {:halt, :rejected}
              end

            _ ->
              {:halt, :rejected}
          end
        end
      )

    if is_map(result) and map_size(result) > 1 and is_binary(profile["capability_token_hash"]) and
         profile["capability_token_hash"] != "",
       do: {:ok, result},
       else: {:error, :no_active_local_media}
  end
end
