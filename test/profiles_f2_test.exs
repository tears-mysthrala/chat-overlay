defmodule ChatOverlay.ProfilesF2Test do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Config, Profiles}

  setup do
    original_profiles = Application.get_env(:chat_overlay, :profiles, [])
    original_objects = Application.get_env(:chat_overlay, :media_objects, [])
    Application.put_env(:chat_overlay, :media_objects, [])

    on_exit(fn ->
      Application.put_env(:chat_overlay, :media_objects, original_objects)
      Application.put_env(:chat_overlay, :profiles, original_profiles)
    end)

    f2_profile = %{
      "handle" => "f2test",
      "sources" => [
        %{"platform" => "twitch", "channel" => "f2test", "mode" => "demo"}
      ]
    }

    profiles = Enum.reject(original_profiles, &(&1["handle"] == "f2test")) ++ [f2_profile]
    Application.put_env(:chat_overlay, :profiles, profiles)
    :ok
  end

  test "verify_capability_token allows access when no token hash is set (backward compat)" do
    assert {:ok, profile} = Profiles.verify_capability_token("f2test", nil)
    assert profile["handle"] == "f2test"

    assert {:ok, profile} = Profiles.verify_capability_token("f2test", "any-random-token")
    assert profile["handle"] == "f2test"
  end

  test "regenerate_capability_token generates valid token, sets hash, and enables verification" do
    assert {:ok, token, updated} = Profiles.regenerate_capability_token("f2test")
    assert is_binary(token)
    # 32 bytes base64url unpadded is 43 chars
    assert byte_size(token) == 43
    assert is_binary(updated["capability_token_hash"])
    assert byte_size(updated["capability_token_hash"]) == 64

    # Verify with correct token succeeds
    assert {:ok, verified} = Profiles.verify_capability_token("f2test", token)
    assert verified["handle"] == "f2test"

    # Verify with wrong token fails with 401 unauthorized
    assert {:error, :unauthorized} = Profiles.verify_capability_token("f2test", "wrong-token")
    assert {:error, :unauthorized} = Profiles.verify_capability_token("f2test", nil)
    assert {:error, :unauthorized} = Profiles.verify_capability_token("f2test", "")

    # Non-existent handle returns not_found
    assert {:error, :not_found} = Profiles.verify_capability_token("nonexistent", token)
  end

  test "regenerate_capability_token revokes previous token" do
    {:ok, token1, _} = Profiles.regenerate_capability_token("f2test")
    assert {:ok, _} = Profiles.verify_capability_token("f2test", token1)

    {:ok, token2, _} = Profiles.regenerate_capability_token("f2test")
    assert token1 != token2

    # Old token is now invalid
    assert {:error, :unauthorized} = Profiles.verify_capability_token("f2test", token1)
    # New token is valid
    assert {:ok, _} = Profiles.verify_capability_token("f2test", token2)
  end

  test "update_media updates alert sound and image and persists" do
    media = %{
      "alert_sound" => %{"url" => "https://cdn.example.com/sound.mp3", "source" => "external"},
      "alert_image" => %{"url" => "https://cdn.example.com/badge.webp", "source" => "r2"}
    }

    assert {:ok, updated} = Profiles.update_media("f2test", media)
    assert updated["media"]["alert_sound"]["url"] == "https://cdn.example.com/sound.mp3"
    assert updated["media"]["alert_image"]["url"] == "https://cdn.example.com/badge.webp"

    profile_in_config = Config.profile("f2test")
    assert profile_in_config["media"] == updated["media"]

    # Updating with empty/nil removes or cleans
    partial = %{
      "alert_sound" => %{"url" => ""},
      "alert_image" => %{"url" => "https://cdn.example.com/newbadge.png", "source" => "external"}
    }

    assert {:ok, updated2} = Profiles.update_media("f2test", partial)
    assert is_nil(updated2["media"]["alert_sound"])
    assert updated2["media"]["alert_image"]["url"] == "https://cdn.example.com/newbadge.png"
  end

  test "update_upload_quota adjusts storage_used_bytes and clamps to 0" do
    assert {:ok, p1} = Profiles.update_upload_quota("f2test", 1024)
    assert p1["storage_used_bytes"] == 1024

    assert {:ok, p2} = Profiles.update_upload_quota("f2test", 2048)
    assert p2["storage_used_bytes"] == 3072

    assert {:ok, p3} = Profiles.update_upload_quota("f2test", -5000)
    assert p3["storage_used_bytes"] == 0
  end

  test "Profiles.list/0 includes F2 metadata and excludes raw hash" do
    {:ok, _token, _} = Profiles.regenerate_capability_token("f2test")

    Profiles.update_media("f2test", %{
      "alert_sound" => %{"url" => "https://cdn.example.com/sound.ogg", "source" => "r2"}
    })

    summary = Profiles.get("f2test")
    assert summary["has_capability_token"] == true
    assert is_nil(summary["capability_token_hash"])
    assert summary["media"]["alert_sound"]["url"] == "https://cdn.example.com/sound.ogg"
    assert summary["can_upload"] == false
    assert summary["storage_quota_bytes"] == 10_485_760
    assert summary["storage_used_bytes"] == 0
  end

  test "atomic computation of storage_used_bytes and quota enforcement (SEC-05, SEC-17)" do
    # 1. Setting R2 media computes exact storage_used_bytes
    media = %{
      "alert_sound" => %{
        "url" => "https://cdn.example.com/audio/alert1.mp3",
        "source" => "r2",
        "key" => "audio/alert1.mp3",
        "size" => 1_000_000
      },
      "alert_image" => %{
        "url" => "https://cdn.example.com/image/badge1.png",
        "source" => "r2",
        "key" => "image/badge1.png",
        "size" => 300_000
      }
    }

    assert {:ok, p1} = Profiles.update_media("f2test", media)
    assert p1["storage_used_bytes"] == 1_300_000

    # 2. Reject update if new total storage exceeds quota (default 10 MB = 10_485_760)
    oversized = %{
      "alert_sound" => %{
        "url" => "https://cdn.example.com/audio/huge.mp3",
        "source" => "r2",
        "key" => "audio/huge.mp3",
        "size" => 10_200_000
      }
    }

    # 10_200_000 + 300_000 = 10_500_000 > 10_485_760
    assert {:error, :quota_exceeded} = Profiles.update_media("f2test", oversized)

    # 3. Replacing an R2 file deducts old size and reports old key in removed_keys
    replacement = %{
      "alert_sound" => %{
        "url" => "https://cdn.example.com/audio/alert2.mp3",
        "source" => "r2",
        "key" => "audio/alert2.mp3",
        "size" => 500_000
      }
    }

    assert {:ok, p2, removed_keys} =
             Profiles.update_media("f2test", replacement, with_removed_keys: true)

    assert p2["storage_used_bytes"] == 800_000
    assert "audio/alert1.mp3" in removed_keys

    # 4. Switching R2 to external frees the R2 quota
    external_switch = %{
      "alert_image" => %{
        "url" => "https://cdn.discordapp.com/emojis/external.png",
        "source" => "external"
      }
    }

    assert {:ok, p3, removed_keys2} =
             Profiles.update_media("f2test", external_switch, with_removed_keys: true)

    assert p3["storage_used_bytes"] == 500_000
    assert "image/badge1.png" in removed_keys2

    # 5. Removing an alert (empty URL) frees remaining R2 quota
    removal = %{
      "alert_sound" => %{"url" => ""}
    }

    assert {:ok, p4, removed_keys3} =
             Profiles.update_media("f2test", removal, with_removed_keys: true)

    assert p4["storage_used_bytes"] == 0
    assert "audio/alert2.mp3" in removed_keys3
  end

  test "deletion preserves untracked legacy R2 references pending reconciliation" do
    Profiles.update_media("f2test", %{
      "alert_sound" => %{
        "url" => "https://cdn.example.com/audio/del_alert.mp3",
        "source" => "r2",
        "key" => "audio/del_alert.mp3",
        "size" => 100_000
      }
    })

    assert {:error, :media_inventory_required} =
             Profiles.delete("f2test", with_removed_keys: true)

    assert Profiles.get("f2test")["media"]["alert_sound"]["key"] == "audio/del_alert.mp3"

    # Nonexistent handle returns 404/not_found
    assert {:error, :not_found} = Profiles.delete("nonexistent_profile", with_removed_keys: true)
  end
end
