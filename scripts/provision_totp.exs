# Run offline in a trusted operator terminal, never in CI with real identities.
result =
  case System.argv() do
    ["prepare", directory, handle, provider, user_id] ->
      ChatOverlay.Reauthentication.Enrollment.prepare(directory, handle, provider, user_id)

    ["confirm", directory] ->
      code = IO.gets("Code from the configured authenticator: ")

      if is_binary(code),
        do: ChatOverlay.Reauthentication.Enrollment.confirm(directory, String.trim(code)),
        else: {:error, :cancelled}

    _ ->
      {:error, :usage}
  end

if result == :ok do
  IO.puts("Operator enrollment step completed. Private files remain in the chosen directory.")
else
  IO.puts(:stderr, "Enrollment failed; existing credentials were not replaced.")
  System.halt(1)
end
