defmodule ChatOverlay.Custodian.ResultTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.Custodian.Result

  defp json(data),
    do: %{"version" => 1, "kind" => "json", "status" => 200, "data" => data, "cookies" => []}

  test "rejects platform tokens even nested in domain metadata" do
    for key <- [
          "access_token",
          "refresh_token",
          "encrypted_tokens",
          "client_secret",
          "encryption_key",
          "db_password"
        ] do
      assert {:error, :response_rejected} =
               Result.validate(json(%{"profile" => %{key => "synthetic"}}))
    end
  end

  test "rejects unknown envelope fields and redirect destinations" do
    assert {:error, :response_rejected} = Result.validate(Map.put(json(%{}), "headers", []))

    for location <- [
          "https://attacker.example/",
          "//attacker.example/",
          "javascript:alert(1)",
          "/\r\nHeader: bad"
        ] do
      assert {:error, :response_rejected} =
               Result.validate(%{
                 "version" => 1,
                 "kind" => "redirect",
                 "status" => 302,
                 "location" => location,
                 "cookies" => []
               })
    end
  end

  test "allows only session and host-only OAuth cookies" do
    cookie = %{
      "name" => "chat_overlay_session",
      "value" => "opaque",
      "max_age" => 600,
      "secure" => true,
      "http_only" => true,
      "same_site" => "Lax",
      "path" => "/"
    }

    assert :ok = Result.validate(Map.put(json(%{}), "cookies", [cookie]))

    oauth_cookie =
      Map.put(cookie, "name", ChatOverlay.OAuthFlow.cookie_name("fixture-state", true))

    assert :ok = Result.validate(Map.put(json(%{}), "cookies", [oauth_cookie]))

    assert :ok =
             Result.validate(Map.put(json(%{}), "cookies", [Map.put(oauth_cookie, "max_age", 0)]))

    for bad <- [
          Map.put(cookie, "secure", false),
          Map.put(cookie, "name", "other"),
          Map.put(cookie, "domain", ".example.test"),
          Map.put(cookie, "max_age", 604_801)
        ] do
      assert {:error, :response_rejected} = Result.validate(Map.put(json(%{}), "cookies", [bad]))
    end
  end

  test "raw media ceiling survives base64 expansion without accepting oversized objects" do
    bytes = :binary.copy(<<0>>, 2_097_152)

    result = %{
      "version" => 1,
      "kind" => "media",
      "status" => 200,
      "mime" => "audio/wav",
      "size" => byte_size(bytes),
      "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
      "bytes" => Base.encode64(bytes)
    }

    assert :ok = Result.validate(result)
    encoded = ChatOverlay.JSON.encode(result)
    assert byte_size(encoded) > 2_097_152
    assert {:ok, ^result} = Result.decode(encoded)
    assert {:error, :response_rejected} = Result.validate(Map.put(result, "size", 2_097_153))
    assert {:error, :response_rejected} = Result.validate(Map.put(result, "sha256", "wrong"))
    assert {:error, :response_rejected} = Result.decode(:binary.copy(" ", Result.max_bytes() + 1))
  end
end
