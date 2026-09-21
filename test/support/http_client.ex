defmodule ChatOverlay.TestClient do
  @moduledoc false
  use GenServer

  def open(host, port, _opts),
    do: GenServer.start_link(__MODULE__, {to_string(host), port, self()})

  def await_up(_), do: {:ok, :http}

  def init({host, port, owner}) do
    {:ok, conn} = Mint.HTTP.connect(:http, host, port, protocols: [:http1])
    {:ok, {conn, owner}}
  end

  def request(pid, method, path, headers, body),
    do: GenServer.call(pid, {:request, method, path, headers, body})

  def get(pid, path, headers \\ []), do: request(pid, "GET", path, headers, "")
  def close(pid), do: if(Process.alive?(pid), do: GenServer.stop(pid), else: :ok)

  def await(pid, ref, timeout \\ 5000) do
    receive do
      {:client_response, ^pid, ^ref, status, headers} -> {:response, :nofin, status, headers}
      {:client_data, ^pid, ^ref, :nofin, data} -> {:data, :nofin, data}
      {:client_done, ^pid, ^ref} -> {:done, ""}
      {:client_down, ^pid, _, _, _} -> {:error, :closed}
    after
      timeout -> {:error, :timeout}
    end
  end

  def await_body(pid, ref, acc \\ "") do
    case await(pid, ref) do
      {:data, :nofin, data} -> await_body(pid, ref, acc <> data)
      {:done, ""} -> {:ok, acc}
      other -> other
    end
  end

  def handle_call({:request, method, path, headers, body}, _, {conn, owner}) do
    {:ok, conn, ref} = Mint.HTTP.request(conn, method, path, headers, body)
    {:reply, ref, {conn, owner}}
  end

  def handle_info(message, {conn, owner}) do
    case Mint.HTTP.stream(conn, message) do
      {:ok, conn, responses} ->
        dispatch(responses, owner)
        {:noreply, {conn, owner}}

      {:error, conn, _reason, responses} ->
        dispatch(responses, owner)
        send(owner, {:client_down, self(), :http, :closed, []})
        {:noreply, {conn, owner}}

      :unknown ->
        {:noreply, {conn, owner}}
    end
  end

  defp dispatch(responses, owner) do
    Enum.each(responses, fn
      {:status, ref, status} ->
        Process.put({:status, ref}, status)

      {:headers, ref, headers} ->
        send(owner, {:client_response, self(), ref, Process.get({:status, ref}), headers})

      {:data, ref, data} ->
        send(owner, {:client_data, self(), ref, :nofin, data})

      {:done, ref} ->
        send(owner, {:client_done, self(), ref})
        Process.delete({:status, ref})
    end)
  end

  def terminate(_, {conn, _}), do: Mint.HTTP.close(conn)
end
