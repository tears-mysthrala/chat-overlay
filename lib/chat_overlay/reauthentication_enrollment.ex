defmodule ChatOverlay.Reauthentication.Enrollment do
  @moduledoc "Offline operator provisioning. Not exposed by HTTP or the custodian RPC protocol."

  def prepare(dir, handle, provider, user_id) do
    if ChatOverlay.Config.handle?(handle) and provider in ["twitch", "youtube"] and
         is_binary(user_id) and byte_size(user_id) in 1..128 do
      # Require a fresh private directory. Never overwrite an existing factor.
      with :ok <- File.mkdir(dir), :ok <- File.chmod(dir, 0o700) do
        secret = NimbleTOTP.secret()

        entry = %{
          "handle" => handle,
          "provider" => provider,
          "user_id" => user_id,
          "secret" => Base.encode32(secret, padding: false)
        }

        with :ok <-
               private_write(Path.join(dir, "pending.json"), ChatOverlay.JSON.encode([entry])),
             :ok <-
               private_write(
                 Path.join(dir, "enrollment.txt"),
                 NimbleTOTP.otpauth_uri("ChatOverlay:" <> handle, secret, issuer: "ChatOverlay") <>
                   "\n"
               ) do
          :ok
        end
      end
    else
      {:error, :invalid_identity}
    end
  end

  def confirm(dir, code) do
    with {:ok, credentials} <-
           ChatOverlay.Reauthentication.load_credentials(Path.join(dir, "pending.json")),
         [credential] <- Map.values(credentials),
         true <- NimbleTOTP.valid?(credential.secret, code),
         {:ok, data} <- File.read(Path.join(dir, "pending.json")),
         :ok <- private_write(Path.join(dir, "credentials.json"), data) do
      File.rm(Path.join(dir, "pending.json"))
      File.rm(Path.join(dir, "enrollment.txt"))
      :ok
    else
      _ -> {:error, :enrollment_not_confirmed}
    end
  end

  defp private_write(path, data) do
    with {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600), :ok <- :file.write(io, data), do: :file.sync(io)
      after
        File.close(io)
      end
    end
  end
end
