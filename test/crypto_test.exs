defmodule ChatOverlay.CryptoTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.Crypto

  describe "Capability Tokens (SEC-14, ADR 0003)" do
    test "generates 32-byte URL-safe capability token" do
      token = Crypto.generate_capability_token()
      assert is_binary(token)
      assert String.length(token) >= 42
      refute String.contains?(token, "+")
      refute String.contains?(token, "/")
      refute String.contains?(token, "=")
    end

    test "hashes token consistently with SHA-256" do
      token = "test-token-12345"
      hash1 = Crypto.hash_token(token)
      hash2 = Crypto.hash_token(token)
      assert hash1 == hash2
      assert byte_size(hash1) == 64
    end

    test "verifies token in constant time and rejects invalid tokens" do
      token = Crypto.generate_capability_token()
      hash = Crypto.hash_token(token)

      assert Crypto.verify_token(token, hash)
      refute Crypto.verify_token("wrong-token", hash)
      refute Crypto.verify_token(token, "corrupted-hash")
      refute Crypto.verify_token(nil, hash)
      refute Crypto.verify_token(token, nil)
    end
  end

  describe "AEAD Symmetric Encryption (SEC-15, ADR 0003)" do
    @test_key :crypto.strong_rand_bytes(32)

    test "encrypts and decrypts with valid key and AAD" do
      plaintext = "twitch_oauth_token_secret_123456789"
      aad = "chat-overlay:platform_token:user_1"

      {:ok, encrypted} = Crypto.encrypt_aead(plaintext, @test_key, aad)
      assert String.starts_with?(encrypted, "v1:")

      {:ok, decrypted} = Crypto.decrypt_aead(encrypted, @test_key, aad)
      assert decrypted == plaintext
    end

    test "fails decryption if AAD does not match" do
      plaintext = "secret-token"
      {:ok, encrypted} = Crypto.encrypt_aead(plaintext, @test_key, "context_a")

      assert {:error, :corrupted_or_invalid_key} =
               Crypto.decrypt_aead(encrypted, @test_key, "context_b")
    end

    test "fails decryption if key is wrong" do
      plaintext = "secret-token"
      other_key = :crypto.strong_rand_bytes(32)
      {:ok, encrypted} = Crypto.encrypt_aead(plaintext, @test_key, "aad")

      assert {:error, :corrupted_or_invalid_key} =
               Crypto.decrypt_aead(encrypted, other_key, "aad")
    end

    test "fails decryption on tampered payload" do
      plaintext = "secret-token"
      {:ok, "v1:" <> payload} = Crypto.encrypt_aead(plaintext, @test_key, "")
      tampered_char = if String.first(payload) == "A", do: "B", else: "A"
      tampered = "v1:" <> tampered_char <> String.slice(payload, 1..-1//1)

      assert {:error, _} = Crypto.decrypt_aead(tampered, @test_key, "")
    end
  end

  describe "OAuth PKCE and Signed State (SEC-14)" do
    test "generates S256 PKCE challenge and verifier" do
      pkce = Crypto.generate_pkce()
      assert pkce.method == "S256"
      assert is_binary(pkce.verifier)
      assert is_binary(pkce.challenge)

      expected_challenge =
        :crypto.hash(:sha256, pkce.verifier)
        |> Base.url_encode64(padding: false)

      assert pkce.challenge == expected_challenge
    end

    test "signs and verifies state with timestamp and secret" do
      secret = "server-secret-key-42"
      data = %{"handle" => "streamer_one", "provider" => "twitch"}

      signed = Crypto.sign_oauth_state(data, secret)
      assert is_binary(signed)

      {:ok, verified} = Crypto.verify_oauth_state(signed, secret)
      assert verified["handle"] == "streamer_one"
      assert verified["provider"] == "twitch"
      assert is_integer(verified["ts"])
    end

    test "rejects state with invalid signature or expired timestamp" do
      secret = "server-secret-key-42"
      data = %{"handle" => "streamer_one"}

      signed = Crypto.sign_oauth_state(data, secret)

      # Invalid secret
      assert {:error, :invalid_signature} = Crypto.verify_oauth_state(signed, "wrong-secret")

      # Expired state
      assert {:error, :expired} = Crypto.verify_oauth_state(signed, secret, -1)
    end
  end

  test "AEAD accepts only canonical URL base64" do
    key = String.duplicate("k", 32)
    {:ok, "v1:" <> encoded} = Crypto.encrypt_aead("a", key, "canonical-test")
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    last = String.last(encoded)
    {index, 1} = :binary.match(alphabet, last)

    alternative =
      binary_part(encoded, 0, byte_size(encoded) - 1) <> binary_part(alphabet, index + 1, 1)

    assert Base.url_decode64(alternative, padding: false) ==
             Base.url_decode64(encoded, padding: false)

    assert {:error, :invalid_payload} =
             Crypto.decrypt_aead("v1:" <> alternative, key, "canonical-test")

    assert {:ok, "a"} = Crypto.decrypt_aead("v1:" <> encoded, key, "canonical-test")
  end
end
