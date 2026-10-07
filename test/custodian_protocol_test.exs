defmodule ChatOverlay.Custodian.ProtocolTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.Custodian.Protocol

  defp request(operation, args),
    do: %{"version" => 1, "operation" => operation, "arguments" => args}

  test "a valid operation preserves opaque user credentials as data" do
    input = request("profiles.delete", %{"handle" => "alice", "session" => "opaque"})
    assert {:ok, ^input} = Protocol.decode(ChatOverlay.JSON.encode(input))
  end

  test "rejects arbitrary calls, unknown versions and caller authorization assertions" do
    for input <- [
          request("Elixir.System.cmd", %{}),
          Map.put(request("session.get", %{}), "version", 2),
          request("profiles.delete", %{"handle" => "alice", "authorized" => true}),
          Map.put(request("session.get", %{}), "url", "http://127.0.0.1")
        ] do
      assert {:error, :invalid_request} = Protocol.decode(ChatOverlay.JSON.encode(input))
    end
  end

  test "rejects malformed profile, provider, view, missing fields and non JSON terms" do
    for {op, args} <- [
          {"profiles.delete", %{"handle" => "../alice"}},
          {"profiles.delete", %{}},
          {"profiles.unlink", %{"handle" => "alice", "provider" => "kick"}},
          {"view.authorize", %{"handle" => "alice", "view" => "admin"}},
          {"profiles.save", %{"document" => %{secret: :atom}}}
        ] do
      assert {:error, :invalid_request} = Protocol.validate(request(op, args))
    end
  end

  test "bounds bytes, nested documents, list sizes and opaque credentials" do
    assert {:error, :invalid_request} = Protocol.decode(String.duplicate(" ", 65_537))
    nested = Enum.reduce(1..10, %{}, fn _, acc -> %{"nested" => acc} end)

    for args <- [
          %{"document" => nested},
          %{"document" => %{"list" => List.duplicate(1, 129)}},
          %{"document" => %{}, "session" => String.duplicate("x", 4097)}
        ] do
      assert {:error, :invalid_request} = Protocol.validate(request("profiles.save", args))
    end
  end

  test "the map entry point cannot bypass the aggregate wire budget" do
    document = %{
      "first" => String.duplicate("a", 40_000),
      "second" => String.duplicate("b", 40_000)
    }

    assert {:error, :invalid_request} =
             Protocol.validate(request("profiles.save", %{"document" => document}))
  end

  test "invalid Unicode and nested runtime values fail closed" do
    assert {:error, :invalid_request} =
             Protocol.validate(request("profiles.delete", %{"handle" => <<255>>}))

    assert {:error, :invalid_request} =
             Protocol.validate(request("profiles.save", %{"document" => %{"value" => self()}}))
  end
end
