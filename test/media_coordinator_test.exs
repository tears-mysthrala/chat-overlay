defmodule ChatOverlay.TestMediaWire do
  import Plug.Conn
  def init(mode), do: mode

  def call(conn, mode) do
    {:ok, body, conn} = read_body(conn, length: 2048)
    {:ok, job} = ChatOverlay.JSON.decode(body)

    cond do
      get_req_header(conn, "authorization") != ["Bearer " <> String.duplicate("t", 43)] ->
        send_resp(conn, 401, "")

      mode == :oversized ->
        send_resp(conn, 200, String.duplicate("x", 2049))

      true ->
        {:ok, report} = ChatOverlay.TestMediaCoordinator.request(conn.request_path, job)
        send_resp(conn, 200, ChatOverlay.JSON.encode(report))
    end
  end
end

defmodule ChatOverlay.MediaCoordinatorTest do
  use ExUnit.Case, async: false

  setup do
    keys = [:media_coordinator_client, :media_coordinator_port, :media_coordinator_token]
    original = Map.new(keys, &{&1, Application.fetch_env(:chat_overlay, &1)})
    Application.delete_env(:chat_overlay, :media_coordinator_client)

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:chat_overlay, key, value)
        {key, :error} -> Application.delete_env(:chat_overlay, key)
      end)
    end)

    :ok
  end

  defp server(mode) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {ChatOverlay.TestMediaWire, mode}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    Application.put_env(:chat_overlay, :media_coordinator_port, port)
  end

  test "authenticated loopback metadata reaches coordinator over real HTTP" do
    server(:normal)

    job = %{
      "job" => String.duplicate("a", 32),
      "handle" => "wire",
      "key" => "wire/image/input.png",
      "category" => "image",
      "size" => 100
    }

    assert {:ok, %{"state" => "ready", "handle" => "wire"}} =
             ChatOverlay.MediaCoordinator.request("/normalize", job)

    Application.put_env(:chat_overlay, :media_coordinator_token, String.duplicate("z", 43))
    assert {:error, :validation_failed} = ChatOverlay.MediaCoordinator.request("/normalize", job)
  end

  test "oversized response is rejected without exposing its body" do
    server(:oversized)

    assert {:error, :coordinator_response_rejected} =
             ChatOverlay.MediaCoordinator.request("/delete", %{
               "bucket" => "public",
               "key" => "wire/image/input.png"
             })
  end
end
