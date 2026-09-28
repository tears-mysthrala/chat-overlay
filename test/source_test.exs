defmodule ChatOverlay.SourceTest do
  use ExUnit.Case, async: false
  alias ChatOverlay.{Source, Config, Admission}

  test "upstream retry deadline survives idle grace and resumed demand" do
    source = hd(Config.profile("test")["sources"])
    {:ok, s} = Source.init(source)
    ref = make_ref()

    {:noreply, waiting} =
      Source.handle_info({ref, {:retry, 3_600_000}}, %{
        s
        | worker: %Task{ref: ref, pid: self(), owner: self(), mfa: nil},
          demand: 1
      })

    Process.cancel_timer(waiting.timer)
    {:noreply, idle} = Source.handle_info(:idle, %{waiting | demand: 0})
    assert idle.next_attempt == waiting.next_attempt
    assert idle.worker == nil and idle.timer == nil
    assert :ok = Admission.acquire("test")

    try do
      {:noreply, resumed} = Source.handle_cast(:acquire, idle)
      assert resumed.worker == nil
      assert is_reference(resumed.timer)
      assert resumed.next_attempt - System.monotonic_time(:millisecond) >= 3_599_000
      Process.cancel_timer(resumed.timer)
    after
      Admission.release()
    end
  end

  test "successful poll interval survives idle shutdown too" do
    source = hd(Config.profile("test")["sources"])
    {:ok, s} = Source.init(source)
    worker = %Task{ref: make_ref(), pid: self(), owner: self(), mfa: nil}

    {:reply, :ok, waiting} =
      Source.handle_call({:defer, 300_000}, {self(), make_ref()}, %{s | worker: worker})

    # Model completed worker shutdown without terminating the test owner.
    {:noreply, idle} = Source.handle_info(:idle, %{waiting | worker: nil})
    assert idle.next_attempt == waiting.next_attempt
    assert :ok = Admission.acquire("test")

    try do
      {:noreply, resumed} = Source.handle_cast(:acquire, idle)
      assert resumed.worker == nil
      assert resumed.next_attempt - System.monotonic_time(:millisecond) >= 299_000
      Process.cancel_timer(resumed.timer)
    after
      Admission.release()
    end
  end

  test "kick source tracks gap state across idle transitions" do
    kick_source = Enum.find(Config.profile("test")["sources"], &(&1["platform"] == "kick"))
    {:ok, s} = Source.init(kick_source)
    assert s.gap == true

    {:noreply, idle} = Source.handle_info(:idle, %{s | gap: false, demand: 0})
    assert idle.gap == true
  end

  test "kick source clears gap when demand resumes" do
    kick_source = Enum.find(Config.profile("test")["sources"], &(&1["platform"] == "kick"))
    {:ok, s} = Source.init(kick_source)
    assert s.gap == true

    assert :ok = Admission.acquire("test")

    try do
      {:noreply, resumed} = Source.handle_cast(:acquire, s)
      assert resumed.gap == false
    after
      Admission.release()
    end
  end

  test "YouTube concurrent streams on the same channel route events to their respective profile stores in isolation" do
    s_horiz = %{
      "platform" => "youtube",
      "channel" => "UC1234567890123456789012",
      "live_chat_id" => "chat_id_horizontal",
      "credential_env" => "CHAT_YOUTUBE_TOKEN"
    }

    s_vert = %{
      "platform" => "youtube",
      "channel" => "UC1234567890123456789012",
      "live_chat_id" => "chat_id_vertical",
      "credential_env" => "CHAT_YOUTUBE_TOKEN"
    }

    profiles = [
      %{
        "handle" => "stream-horizontal",
        "overlay_platforms" => ["youtube"],
        "sources" => [s_horiz]
      },
      %{"handle" => "stream-vertical", "overlay_platforms" => ["youtube"], "sources" => [s_vert]}
    ]

    previous = Application.get_env(:chat_overlay, :profiles)
    Application.put_env(:chat_overlay, :profiles, profiles)
    on_exit(fn -> Application.put_env(:chat_overlay, :profiles, previous) end)

    start_supervised!(ChatOverlay.Store.child_spec(hd(profiles)))
    start_supervised!(ChatOverlay.Store.child_spec(List.last(profiles)))

    event_horiz =
      ChatOverlay.Event.new(
        "youtube",
        "UC1234567890123456789012",
        "message",
        "msg-horiz-1",
        %{
          "message_id" => "msg-horiz-1",
          "author_id" => "u1",
          "author_display" => "User Horizontal",
          "text" => "Horizontal chat"
        },
        session: "chat_id_horizontal"
      )

    event_vert =
      ChatOverlay.Event.new(
        "youtube",
        "UC1234567890123456789012",
        "message",
        "msg-vert-1",
        %{
          "message_id" => "msg-vert-1",
          "author_id" => "u2",
          "author_display" => "User Vertical",
          "text" => "Vertical chat"
        },
        session: "chat_id_vertical"
      )

    assert Source.publish(s_horiz, event_horiz)
    assert Source.publish(s_vert, event_vert)

    %{events: [_, %{"payload" => %{"messages" => horiz_msgs}}]} =
      ChatOverlay.Store.read(ChatOverlay.Store.name("stream-horizontal"))

    assert length(horiz_msgs) == 1
    assert hd(horiz_msgs)["payload"]["text"] == "Horizontal chat"

    %{events: [_, %{"payload" => %{"messages" => vert_msgs}}]} =
      ChatOverlay.Store.read(ChatOverlay.Store.name("stream-vertical"))

    assert length(vert_msgs) == 1
    assert hd(vert_msgs)["payload"]["text"] == "Vertical chat"
  end
end
