defmodule ChatOverlay.SocketTest do
  use ExUnit.Case, async: true
  alias ChatOverlay.Socket

  test "real Mint handshake, fragmented text, ping and peer close" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, request} = :gen_tcp.recv(socket, 0, 5000)
        [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)\r/i, request)

        accept =
          :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ",
            accept,
            "\r\n\r\n",
            <<1, 2>>,
            "he",
            <<128, 3>>,
            "llo",
            <<137, 1>>,
            "x"
          ])

        {:ok, pong} = :gen_tcp.recv(socket, 0, 5000)
        assert <<138, 129, _::binary>> = pong
        :gen_tcp.send(socket, <<136, 2, 3, 232>>)
        :gen_tcp.close(socket)
      end)

    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive, protocols: [:http1])
    assert {:ok, s} = Socket.upgrade(conn, "/ws", :ws)
    assert {:ok, {:text, "hello"}, s} = Socket.recv(s, 1000)
    assert {:ok, {:ping, "x"}, s} = Socket.recv(s, 1000)
    assert {:error, :timeout} = Socket.recv(s, 1)
    assert {:ok, s} = Socket.pong(s, "x")
    assert {:ok, {:close, 1000, ""}, s} = Socket.recv(s, 1000)
    assert {:error, :connection_lost} = Socket.recv(s, 1000)
    Socket.close(s)
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "fragment buffers and frame counts stay bounded" do
    s = %{ws: %Mint.WebSocket{}, frames: []}
    assert {:ok, s} = Socket.decode(s, <<1, 126, 255, 255>> <> String.duplicate("a", 65535))
    assert {:error, :incomplete_frame} = Socket.recv(s, 0)
    assert {:error, :too_large} = Socket.decode(s, String.duplicate("a", 262_144))

    assert {:error, :invalid_frame} =
             Socket.decode(
               %{ws: %Mint.WebSocket{}, frames: []},
               :binary.copy(<<129, 1, ?x>>, 129)
             )
  end

  test "failed upgrade rejects a streaming response before buffering its body" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

        :ok =
          :gen_tcp.send(socket, "HTTP/1.1 503 Unavailable\r\nContent-Length: 999999999\r\n\r\n")

        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2000)
      end)

    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive, protocols: [:http1])
    assert {:error, :upgrade_failed} = Socket.upgrade(conn, "/ws", :ws)
    Task.await(server)
    :gen_tcp.close(listener)
  end
end
