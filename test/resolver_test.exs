defmodule ChatOverlay.ResolverTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.Resolver

  test "clean_twitch_slug normalizes usernames, handles, and URLs" do
    assert {:ok, "revenant"} = Resolver.clean_twitch_slug("revenant")
    assert {:ok, "revenant"} = Resolver.clean_twitch_slug("@revenant")
    assert {:ok, "revenant"} = Resolver.clean_twitch_slug("https://www.twitch.tv/revenant")

    assert {:ok, "revenant"} =
             Resolver.clean_twitch_slug("https://twitch.tv/popout/revenant/chat")

    assert {:ok, "revenant"} = Resolver.clean_twitch_slug("twitch.tv/revenant")
    assert {:ok, "revenant"} = Resolver.clean_twitch_slug("www.twitch.tv/revenant/")
    assert {:ok, "ibai"} = Resolver.clean_twitch_slug("IBAI")
    assert {:ok, "38446500"} = Resolver.clean_twitch_slug("38446500")

    assert {:error, :invalid_twitch_channel} = Resolver.clean_twitch_slug("")

    assert {:error, :invalid_twitch_channel} =
             Resolver.clean_twitch_slug("invalid name with spaces")

    assert {:error, :invalid_twitch_channel} = Resolver.clean_twitch_slug("<script>")

    assert {:error, :invalid_twitch_channel} =
             Resolver.clean_twitch_slug("https://evil.test/revenant")
  end

  test "clean_youtube_target classifies video URLs, handles, and channel IDs" do
    assert {:ok, {:video, "wG3nr37RwCs"}} =
             Resolver.clean_youtube_target("https://www.youtube.com/watch?v=wG3nr37RwCs")

    assert {:ok, {:video, "wG3nr37RwCs"}} =
             Resolver.clean_youtube_target("https://www.youtube.com/live/wG3nr37RwCs")

    assert {:ok, {:video, "wG3nr37RwCs"}} =
             Resolver.clean_youtube_target("https://www.youtube.com/live/wG3nr37RwCs/")

    assert {:ok, {:video, "wG3nr37RwCs"}} =
             Resolver.clean_youtube_target("youtube.com/watch?v=wG3nr37RwCs")

    assert {:ok, {:video, "wG3nr37RwCs"}} =
             Resolver.clean_youtube_target("https://youtu.be/wG3nr37RwCs")

    assert {:ok, {:video, "wG3nr37RwCs"}} =
             Resolver.clean_youtube_target("youtu.be/wG3nr37RwCs")

    assert {:ok, {:handle, "HAKODATELIVECAMERA"}} =
             Resolver.clean_youtube_target("https://www.youtube.com/@HAKODATELIVECAMERA")

    assert {:ok, {:handle, "HAKODATELIVECAMERA"}} =
             Resolver.clean_youtube_target("youtube.com/@HAKODATELIVECAMERA")

    assert {:ok, {:handle, "HAKODATELIVECAMERA"}} =
             Resolver.clean_youtube_target("@HAKODATELIVECAMERA")

    assert {:ok, {:channel, "UCynX4LJTQ_H7_KPy7QiIS2A"}} =
             Resolver.clean_youtube_target(
               "https://www.youtube.com/channel/UCynX4LJTQ_H7_KPy7QiIS2A"
             )

    assert {:ok, {:channel, "UCynX4LJTQ_H7_KPy7QiIS2A"}} =
             Resolver.clean_youtube_target("UCynX4LJTQ_H7_KPy7QiIS2A")

    assert {:error, :invalid_youtube_target} =
             Resolver.clean_youtube_target("https://evil.test/bad")
  end

  test "discover_twitch_youtube extracts YouTube URLs from description fallback" do
    desc = "¡Hola a todos! Sígueme también en https://www.youtube.com/@mi_canal y en twitter."

    assert {:ok, "https://www.youtube.com/@mi_canal"} =
             Resolver.discover_twitch_youtube("nonexistent_user_xyz", description: desc)

    short_desc = "VODs en https://youtu.be/abc123xyz89"

    assert {:ok, "https://youtu.be/abc123xyz89"} =
             Resolver.discover_twitch_youtube("nonexistent_user_xyz", description: short_desc)

    no_yt = "Solo juego videojuegos aquí. Sin redes."

    assert {:error, :no_youtube_link} =
             Resolver.discover_twitch_youtube("nonexistent_user_xyz", description: no_yt)

    assert {:error, :invalid_login} = Resolver.discover_twitch_youtube(12345)
  end
end
