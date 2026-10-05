defmodule ChatOverlay.MediaTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.Media

  describe "Media Type Validation and Limits (SEC-05, SEC-17)" do
    test "accepts valid audio formats within 2 MB" do
      for ext <- [".mp3", ".ogg", ".wav", ".webm"] do
        mime =
          case ext do
            ".mp3" -> "audio/mpeg"
            ".ogg" -> "audio/ogg"
            ".wav" -> "audio/wav"
            ".webm" -> "audio/webm"
          end

        params = %{
          "filename" => "alert#{ext}",
          "content_type" => mime,
          "size" => 1_500_000
        }

        assert {:ok, res} = Media.validate_upload_request(params, 0)
        assert res.category == :audio
        assert res.ext == ext
        assert res.mime == mime
        assert String.starts_with?(res.key, "audio/")
      end
    end

    test "accepts valid image/emoji formats within 512 KB" do
      for ext <- [".webp", ".png", ".gif"] do
        mime = "image/#{String.trim_leading(ext, ".")}"

        params = %{
          "filename" => "emoji#{ext}",
          "content_type" => mime,
          "size" => 350_000
        }

        assert {:ok, res} = Media.validate_upload_request(params, 0)
        assert res.category == :image
        assert res.ext == ext
        assert res.mime == mime
        assert String.starts_with?(res.key, "image/")
      end
    end

    test "strictly prohibits .svg files to prevent XSS in OBS" do
      params = %{
        "filename" => "malicious.svg",
        "content_type" => "image/svg+xml",
        "size" => 10_000
      }

      assert {:error, :svg_prohibited_for_security} =
               Media.validate_upload_request(params, 0)
    end

    test "rejects files exceeding size limits" do
      # Audio > 2 MB
      audio_params = %{
        "filename" => "huge.mp3",
        "content_type" => "audio/mpeg",
        "size" => 2_500_000
      }

      assert {:error, :file_too_large} = Media.validate_upload_request(audio_params, 0)

      # Image > 512 KB
      image_params = %{
        "filename" => "huge.png",
        "content_type" => "image/png",
        "size" => 600_000
      }

      assert {:error, :file_too_large} = Media.validate_upload_request(image_params, 0)
    end

    test "rejects mismatched MIME types" do
      params = %{
        "filename" => "fake.mp3",
        "content_type" => "image/png",
        "size" => 500_000
      }

      assert {:error, :mismatched_content_type} = Media.validate_upload_request(params, 0)
    end

    test "enforces user storage quota" do
      quota = 10_000_000

      params = %{
        "filename" => "sound.mp3",
        "content_type" => "audio/mpeg",
        "size" => 1_500_000
      }

      # Already used 9 MB -> 9 MB + 1.5 MB > 10 MB quota
      assert {:error, :quota_exceeded} = Media.validate_upload_request(params, 9_000_000, quota)

      # Already used 8 MB -> 8 MB + 1.5 MB <= 10 MB quota
      assert {:ok, _} = Media.validate_upload_request(params, 8_000_000, quota)
    end
  end

  describe "External URL Validation" do
    test "accepts valid https URLs for audio and images" do
      assert {:ok, "https://8.8.8.8/attachments/123/alert.mp3"} =
               Media.validate_external_url(
                 "https://8.8.8.8/attachments/123/alert.mp3",
                 :audio
               )

      assert {:ok, "https://1.1.1.1/emojis/pog.webp"} =
               Media.validate_external_url("https://1.1.1.1/emojis/pog.webp", :image)
    end

    test "rejects non-https, svg, or mismatched categories" do
      # HTTP rejected
      assert {:error, :invalid_url} =
               Media.validate_external_url("http://cdn.example.com/alert.mp3", :audio)

      # SVG rejected
      assert {:error, :svg_prohibited_for_security} =
               Media.validate_external_url("https://cdn.example.com/image.svg", :image)

      # Category mismatch
      assert {:error, :category_mismatch} =
               Media.validate_external_url("https://cdn.example.com/sound.mp3", :image)
    end
  end

  describe "S3 / Cloudflare R2 Presigned PUT URLs (SigV4)" do
    test "generates valid SigV4 presigned PUT URL" do
      config = %{
        endpoint: "https://myaccount.r2.cloudflarestorage.com",
        bucket: "chat-overlay-media",
        key: "audio/test_alert.mp3",
        content_type: "audio/mpeg",
        access_key_id: "test_access_key",
        secret_access_key: "test_secret_key",
        public_cdn_base: "https://media.mysthrala.com",
        expires_in: 300
      }

      assert {:ok, res} = Media.generate_presigned_put(config)
      assert res.public_url == "https://media.mysthrala.com/audio/test_alert.mp3"
      assert is_binary(res.upload_url)
      assert String.contains?(res.upload_url, "X-Amz-Algorithm=AWS4-HMAC-SHA256")
      assert String.contains?(res.upload_url, "X-Amz-Credential=test_access_key")
      assert String.contains?(res.upload_url, "X-Amz-Expires=300")
      assert String.contains?(res.upload_url, "X-Amz-SignedHeaders=host")
      assert String.contains?(res.upload_url, "X-Amz-Signature=")
    end

    test "generates upload_token when metadata is provided" do
      config = %{
        endpoint: "https://myaccount.r2.cloudflarestorage.com",
        bucket: "chat-overlay-media",
        key: "audio/test_alert.mp3",
        content_type: "audio/mpeg",
        access_key_id: "test_access_key",
        secret_access_key: "test_secret_key",
        handle: "streamer",
        size: 50_000,
        category: :audio
      }

      assert {:ok, res} = Media.generate_presigned_put(config)
      assert is_binary(res[:upload_token])

      assert {:ok, verified} =
               Media.verify_upload_token(res[:upload_token], "streamer", "audio/test_alert.mp3")

      assert verified.size == 50_000
      assert verified.category == "audio"
    end
  end

  describe "S3 / Cloudflare R2 Presigned DELETE URLs (SigV4)" do
    test "generates valid SigV4 presigned DELETE URL" do
      config = %{
        endpoint: "https://myaccount.r2.cloudflarestorage.com",
        bucket: "chat-overlay-media",
        key: "audio/old_alert.mp3",
        access_key_id: "test_access_key",
        secret_access_key: "test_secret_key",
        expires_in: 300
      }

      assert {:ok, res} = Media.generate_presigned_delete(config)
      assert res.key == "audio/old_alert.mp3"
      assert is_binary(res.delete_url)

      assert String.starts_with?(
               res.delete_url,
               "https://myaccount.r2.cloudflarestorage.com/chat-overlay-media/audio/old_alert.mp3?"
             )

      assert String.contains?(res.delete_url, "X-Amz-Algorithm=AWS4-HMAC-SHA256")
      assert String.contains?(res.delete_url, "X-Amz-Credential=test_access_key")
      assert String.contains?(res.delete_url, "X-Amz-Expires=300")
      assert String.contains?(res.delete_url, "X-Amz-SignedHeaders=host")
      assert String.contains?(res.delete_url, "X-Amz-Signature=")
    end

    test "presigned_delete_url uses default R2 configuration" do
      assert {:ok, res} = Media.presigned_delete_url("image/replaced.png")
      assert res.key == "image/replaced.png"
      assert is_binary(res.delete_url)
      assert String.contains?(res.delete_url, "X-Amz-Signature=")
      assert String.contains?(res.delete_url, "image/replaced.png")
    end
  end

  describe "Upload Token Anti-Tampering (SEC-05, SEC-17)" do
    test "verifies valid upload token and returns size and category" do
      assert {:ok, token} =
               Media.generate_upload_token("myhandle", "audio/sound.mp3", 12345, :audio)

      assert {:ok, res} = Media.verify_upload_token(token, "myhandle", "audio/sound.mp3")
      assert res.size == 12345
      assert res.category == "audio"
    end

    test "rejects mismatched handle or key" do
      assert {:ok, token} =
               Media.generate_upload_token("myhandle", "audio/sound.mp3", 12345, :audio)

      assert {:error, :invalid_upload_token} =
               Media.verify_upload_token(token, "otherhandle", "audio/sound.mp3")

      assert {:error, :invalid_upload_token} =
               Media.verify_upload_token(token, "myhandle", "audio/different.mp3")
    end

    test "rejects corrupted or forged token" do
      assert {:error, :invalid_upload_token} =
               Media.verify_upload_token("invalid.token.data", "myhandle", "key")
    end
  end
end
