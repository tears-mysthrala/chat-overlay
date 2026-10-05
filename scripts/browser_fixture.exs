# MIX_ENV=test mix run --no-start --no-halt scripts/browser_fixture.exs NEW_PRIVATE_DIR
# Isolated synthetic server for browser/OBS verification. Never use production data.
if Mix.env() != :test, do: raise("Browser fixture requires MIX_ENV=test")
[dir] = System.argv()
:ok = File.mkdir(dir)
:ok = File.chmod(dir, 0o700)
path = Path.join(dir, "profiles.json")

profiles =
  Enum.map(["alice", "bob"], fn handle ->
    %{
      "handle" => handle,
      "sources" => [%{"platform" => "twitch", "channel" => handle, "mode" => "demo"}],
      "can_upload" => false,
      "linked_accounts" => %{
        "twitch" => %{"user_id" => "synthetic-#{handle}", "account_version" => 1}
      }
    }
  end)

Application.put_env(:chat_overlay, :profiles, profiles)
Application.put_env(:chat_overlay, :profiles_path, path)
Application.put_env(:chat_overlay, :media_objects, [])
Application.put_env(:chat_overlay, :port, 4143)

bind =
  case System.get_env("BROWSER_FIXTURE_CONTAINER") do
    nil -> {127, 0, 0, 1}
    "1" -> {0, 0, 0, 0}
    _ -> raise("Invalid browser fixture container opt-in")
  end

Application.put_env(:chat_overlay, :bind, bind)
Application.put_env(:chat_overlay, :http, true)
Application.put_env(:chat_overlay, :encryption_key, Base.encode16(:crypto.strong_rand_bytes(32)))

Application.put_env(:chat_overlay, :oauth_http_client, fn
  :post, "https://id.twitch.tv/oauth2/token", _, _ ->
    {:ok, 200,
     %{
       "access_token" => "synthetic-access",
       "refresh_token" => "synthetic-refresh",
       "expires_in" => 3600
     }}

  :get, "https://api.twitch.tv/helix/users", _, _ ->
    {:ok, 200,
     %{
       "data" => [
         %{"id" => "synthetic-alice", "login" => "alice", "display_name" => "Alice fixture"}
       ]
     }}

  _, _, _, _ ->
    {:error, :fixture_destination_rejected}
end)

{:ok, _} = Application.ensure_all_started(:chat_overlay)
:ok = ChatOverlay.ProfileStorage.write(path, profiles, [])
IO.puts("Synthetic browser fixture ready on http://127.0.0.1:4143; all sources are demo.")
