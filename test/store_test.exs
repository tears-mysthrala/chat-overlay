defmodule ChatOverlay.StoreTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.{Event, Store}

  setup do
    store =
      start_supervised!(%{
        id: Store,
        start:
          {Store, :start_link,
           [
             [
               sources: [
                 %{"platform" => "twitch", "channel" => "one"},
                 %{"platform" => "youtube", "channel" => "two"}
               ]
             ]
           ]}
      })

    %{store: store}
  end

  defp message(id, opts \\ []) do
    Event.new(
      opts[:platform] || "twitch",
      opts[:channel] || "one",
      "message",
      opts[:event_id] || "event-#{id}",
      %{
        "message_id" => to_string(id),
        "author_id" => opts[:author] || "author",
        "author_display" => "Nombre repetido",
        "text" => opts[:text] || "Hola"
      },
      occurred_at: opts[:at] || "2026-09-20T10:00:00Z"
    )
  end

  defp visible(store) do
    %{events: [_, %{"event" => "snapshot", "payload" => p}]} = Store.read(store)
    p["messages"]
  end

  test "dedup uses event type and source; profiles reject foreign sources", %{store: s} do
    assert :ok = Store.ingest(s, message(1))
    assert :duplicate = Store.ingest(s, message(1))
    assert :ok = Store.ingest(s, message(1, platform: "youtube", channel: "two"))
    assert {:error, :invalid_event} = Store.ingest(s, message(2, channel: "private"))
    assert length(visible(s)) == 2
    deletion = Event.new("twitch", "one", "delete_message", "event-1", %{"message_id" => "1"})
    assert :ok = Store.ingest(s, deletion)
    assert [%{"platform" => "youtube"}] = visible(s)

    assert {:error, :deleted} =
             Store.ingest(s, message(1, event_id: "new-id", at: "2026-09-21T10:00:00Z"))
  end

  test "author deletion ignores display names and suppresses delayed history", %{store: s} do
    Store.ingest(s, message(1, author: "a"))
    Store.ingest(s, message(2, author: "b"))

    Store.ingest(
      s,
      Event.new("twitch", "one", "delete_author", "delete", %{"author_id" => "a"},
        occurred_at: "2026-09-20T11:00:00Z"
      )
    )

    assert [%{"payload" => %{"author_id" => "b"}}] = visible(s)
    assert {:error, :deleted} = Store.ingest(s, message(3, author: "a"))
    assert :ok = Store.ingest(s, message(4, author: "a", at: "2026-09-20T12:00:00Z"))
  end

  test "clear and replay cannot restore deleted messages", %{store: s} do
    Store.ingest(s, message(1))
    cursor = Store.read(s).cursor
    Store.ingest(s, Event.new("twitch", "one", "clear_channel", "clear", %{"scope" => "channel"}))
    assert [%{"event" => "reset"}, %{"event" => "snapshot"}] = Store.read(s, cursor).events
    assert [] = visible(s)
    assert {:error, :deleted} = Store.ingest(s, message(2))

    assert [%{"event" => "reset"}, %{"event" => "snapshot", "payload" => %{"messages" => []}}] =
             Store.read(s, "old:1").events
  end

  test "history, dedup and replay are bounded; slow viewer gets reset", %{store: s} do
    cursor = Store.read(s).cursor
    for n <- 1..4200, do: assert(:ok == Store.ingest(s, message(n)))
    assert length(visible(s)) == 100
    assert [%{"event" => "reset"}, _] = Store.read(s, cursor).events
    state = :sys.get_state(s)
    assert length(state.ring) == 512
    assert map_size(state.seen) == 4096
    assert :queue.len(state.seen_order) == 4096
    assert Store.read(s, Store.read(s).cursor).events == []
  end

  test "expiry replaces visible state and replay ends in that snapshot", %{store: s} do
    Store.ingest(s, message(1))
    cursor = Store.read(s).cursor

    :sys.replace_state(s, fn state ->
      %{
        state
        | messages:
            Enum.map(
              state.messages,
              &Map.put(&1, :expires, System.monotonic_time(:millisecond) - 1)
            )
      }
    end)

    assert [%{"event" => "reset"}, %{"event" => "snapshot", "payload" => %{"messages" => []}}] =
             Store.read(s, cursor).events

    assert [] == visible(s)
  end

  test "replacement cannot create an absent message", %{store: s} do
    replacement =
      Event.new("twitch", "one", "replace", "r1", %{
        "message_id" => "1",
        "message" => message(1)["payload"]
      })

    assert {:error, :missing_message} = Store.ingest(s, replacement)
    Store.ingest(s, message(1))
    assert :ok = Store.ingest(s, put_in(replacement, ["payload", "message", "text"], "Edited"))
    assert [%{"payload" => %{"text" => "Edited"}}] = visible(s)
  end

  test "deletion barriers never move backwards and floods reset all sources within bounds", %{
    store: s
  } do
    for {id, at} <- [{"new", "2026-09-20T12:00:00Z"}, {"late", "2026-09-20T11:00:00Z"}] do
      assert :ok =
               Store.ingest(
                 s,
                 Event.new("twitch", "one", "delete_author", id, %{"author_id" => "author"},
                   occurred_at: at
                 )
               )
    end

    assert {:error, :deleted} = Store.ingest(s, message(1, at: "2026-09-20T11:30:00Z"))

    for n <- 1..4095 do
      assert :ok =
               Store.ingest(
                 s,
                 Event.new("twitch", "one", "delete_message", "delete-#{n}", %{
                   "message_id" => "#{n}"
                 })
               )
    end

    cursor = Store.read(s).cursor

    assert :ok =
             Store.ingest(
               s,
               Event.new("youtube", "two", "delete_message", "overflow", %{
                 "message_id" => "other"
               })
             )

    assert map_size(:sys.get_state(s).barriers) == 2
    assert [%{"event" => "reset"}, _] = Store.read(s, cursor).events
    assert {:error, :deleted} = Store.ingest(s, message(5000))
  end

  test "deleted text is purged from replay even with no visible history", %{store: s} do
    before = Store.read(s).cursor
    assert :ok = Store.ingest(s, message(1, text: "deleted-private-text"))

    assert :ok =
             Store.ingest(
               s,
               Event.new("twitch", "one", "delete_message", "delete", %{"message_id" => "1"})
             )

    refute ChatOverlay.JSON.encode(Store.read(s, before).events) =~ "deleted-private-text"
    refute inspect(:sys.get_state(s).ring) =~ "deleted-private-text"

    :sys.replace_state(s, fn state ->
      %{
        state
        | ring:
            Enum.map(state.ring, &Map.put(&1, :expires, System.monotonic_time(:millisecond) - 1))
      }
    end)

    old = Store.read(s).cursor
    assert :sys.get_state(s).ring == []
    assert Store.read(s, old).events == []
  end

  test "capacity evictions reach a platform-filtered viewer", %{store: s} do
    assert :ok = Store.ingest(s, message(1))
    cursor = Store.read(s).cursor

    for n <- 1..100,
        do: assert(:ok == Store.ingest(s, message(n, platform: "youtube", channel: "two")))

    events = Store.read(s, cursor).events |> ChatOverlay.Stream.filter_events(["twitch"])
    assert [%{"event" => "delete_message", "payload" => %{"message_id" => "1"}}] = events
    refute Map.has_key?(hd(events), "local_sequence")
    assert Enum.all?(visible(s), &(&1["platform"] == "youtube"))
  end

  test "delayed bulk deletion preserves messages newer than its effective cutoff", %{store: s} do
    assert :ok = Store.ingest(s, message(1, at: "2026-09-20T11:59:00Z"))
    assert :ok = Store.ingest(s, message(2, at: "2026-09-20T12:01:00Z"))

    for {type, payload} <- [
          {"delete_author", %{"author_id" => "author"}},
          {"clear_channel", %{"scope" => "channel"}}
        ] do
      assert :ok =
               Store.ingest(
                 s,
                 Event.new("twitch", "one", type, type, payload,
                   occurred_at: "2026-09-20T12:00:00Z"
                 )
               )

      assert [%{"payload" => %{"message_id" => "2"}}] = visible(s)
    end
  end
end
