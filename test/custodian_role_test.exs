defmodule ChatOverlay.Custodian.RoleTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.Custodian.Role

  test "front accepts only its transport identity and public configuration" do
    assert :ok =
             Role.assert_safe_frontend!(%{"CHAT_CUSTODIAN_TLS_DIR" => "/transport"}, profiles: [])
  end

  test "private credential configuration prevents public startup" do
    for name <-
          ~w(CHAT_ENCRYPTION_KEY CHAT_DB_RUNTIME_PASSWORD TWITCH_CLIENT_SECRET
                   GOOGLE_CLIENT_SECRET MEDIA_COORDINATOR_TOKEN R2_SECRET_ACCESS_KEY CHAT_TWITCH_TOKEN) do
      assert_raise ArgumentError, fn -> Role.assert_safe_frontend!(%{name => "synthetic"}, []) end
    end

    for config <- [
          [postgres_runtime: [password: "synthetic"]],
          [encryption_key: "synthetic"],
          [profiles: [%{"handle" => "private"}]],
          [media_objects: [%{}]]
        ] do
      assert_raise ArgumentError, fn -> Role.assert_safe_frontend!(%{}, config) end
    end
  end

  test "unknown roles are not silently treated as combined" do
    assert_raise ArgumentError, fn -> Role.parse!("fronted") end
  end
end
