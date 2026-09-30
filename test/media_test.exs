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
  end
end
