defmodule ChatOverlay.Custodian.Protocol do
  @moduledoc "Closed v1 input boundary. No caller-selected modules, URLs or authorization decisions."
  @max_bytes 65_536
  @common %{"session" => 4096, "origin" => 256, "requester" => 45}
  @operations %{
    "session.get" => %{},
    "session.logout" => %{},
    "profiles.list" => %{},
    "profiles.save" => %{"document" => :document},
    "profiles.delete" => %{"handle" => :handle},
    "profiles.resolve" => %{"target" => 2048, "platform" => :platform},
    "profiles.sync_youtube" => %{"handle" => :handle},
    "profiles.rotate_capability" => %{"handle" => :handle},
    "profiles.unlink" => %{"handle" => :handle, "provider" => :provider},
    "media.reserve" => %{"document" => :document},
    "media.validate" => %{"document" => :document},
    "media.save" => %{"handle" => :handle, "document" => :document},
    "media.preview" => %{"handle" => :handle, "document" => :document},
    "media.read" => %{"key" => 256},
    "media.upload_authorize" => %{
      "handle" => :handle,
      "key" => 256,
      "upload_token" => 4096,
      "mime" => 64
    },
    "media.upload" => %{"handle" => :handle, "key" => 256, "upload_token" => 4096, "mime" => 64},
    "oauth.begin" => %{
      "handle" => :handle,
      "provider" => :provider,
      "capability" => 4096
    },
    "oauth.complete" => %{
      "provider" => :provider,
      "state" => 8192,
      "code" => 4096,
      "error" => 256,
      "browser" => 4096
    },
    "view.authorize" => %{"handle" => :handle, "view" => :view, "capability" => 4096},
    "events.subscribe" => %{
      "handle" => :handle,
      "view" => :view,
      "capability" => 4096,
      "cursor" => 256
    },
    "health.ready" => %{}
  }
  @required %{
    "profiles.save" => ["document"],
    "profiles.delete" => ["handle"],
    "profiles.resolve" => ["target"],
    "profiles.sync_youtube" => ["handle"],
    "profiles.rotate_capability" => ["handle"],
    "profiles.unlink" => ["handle", "provider"],
    "media.reserve" => ["document"],
    "media.validate" => ["document"],
    "media.save" => ["handle", "document"],
    "media.preview" => ["handle", "document"],
    "media.read" => ["key"],
    "media.upload_authorize" => ["handle", "key", "upload_token", "mime"],
    "media.upload" => ["handle", "key", "upload_token", "mime"],
    "oauth.begin" => ["handle", "provider"],
    "oauth.complete" => ["provider", "state", "browser"],
    "view.authorize" => ["handle", "view"],
    "events.subscribe" => ["handle", "view"]
  }

  def operations, do: Map.keys(@operations) |> Enum.sort()

  def decode(bytes) do
    with true <- is_binary(bytes) and byte_size(bytes) <= @max_bytes,
         {:ok, request} <- ChatOverlay.JSON.decode(bytes),
         :ok <- validate(request) do
      {:ok, request}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def validate(%{"version" => 1, "operation" => operation, "arguments" => args} = request)
      when map_size(request) == 3 and is_map(args) do
    with {:ok, fields} <- Map.fetch(@operations, operation),
         schema = Map.merge(@common, fields),
         true <- Enum.all?(Map.get(@required, operation, []), &Map.has_key?(args, &1)),
         true <- Enum.all?(args, fn {key, value} -> valid_field?(schema[key], value) end),
         true <- byte_size(ChatOverlay.JSON.encode(request)) <= @max_bytes do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  def validate(_), do: {:error, :invalid_request}

  defp valid_field?(:handle, value) when is_binary(value),
    do:
      byte_size(value) in 1..40 and String.valid?(value) and
        Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,39}\z/, value)

  defp valid_field?(:provider, value), do: value in ["twitch", "youtube"]
  defp valid_field?(:platform, value), do: value in ["twitch", "youtube", "auto"]
  defp valid_field?(:view, value), do: value in ["reader", "overlay"]
  defp valid_field?(:document, value) when is_map(value), do: document?(value, 0)

  defp valid_field?(limit, value) when is_integer(limit) and is_binary(value),
    do: byte_size(value) <= limit and String.valid?(value)

  defp valid_field?(_, _), do: false

  # Domain handlers must still apply their own field schema and authorization.
  # This boundary only admits JSON values, never runtime terms or atoms.
  defp document?(_, depth) when depth > 8, do: false
  defp document?(value, _) when is_binary(value), do: String.valid?(value)
  defp document?(value, _) when is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp document?(value, depth) when is_list(value),
    do: length(value) <= 128 and Enum.all?(value, &document?(&1, depth + 1))

  defp document?(value, depth) when is_map(value),
    do:
      map_size(value) <= 64 and
        Enum.all?(value, fn {k, v} ->
          is_binary(k) and byte_size(k) <= 128 and String.valid?(k) and document?(v, depth + 1)
        end)

  defp document?(_, _), do: false
end
