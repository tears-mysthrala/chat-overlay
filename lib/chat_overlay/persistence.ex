defmodule ChatOverlay.Persistence do
  @moduledoc "Explicit storage selection. JSON is a local demo backend, never an RLS fallback."
  def backend do
    case Application.fetch_env!(:chat_overlay, :persistence_backend) do
      backend when backend in [:json_demo, :postgres] -> backend
      _ -> raise "Invalid persistence backend"
    end
  end

  def children do
    pools =
      case backend() do
        :json_demo ->
          []

        :postgres ->
          [
            Supervisor.child_spec(
              {Postgrex,
               Application.fetch_env!(:chat_overlay, :postgres_runtime) ++
                 [name: ChatOverlay.Postgres.Runtime]},
              id: :postgres_runtime
            ),
            Supervisor.child_spec(
              {Postgrex,
               Application.fetch_env!(:chat_overlay, :postgres_bootstrap) ++
                 [name: ChatOverlay.Postgres.Bootstrap]},
              id: :postgres_bootstrap
            )
          ]
      end

    pools ++ [ChatOverlay.Persistence.Loader]
  end
end

defmodule ChatOverlay.Persistence.Loader do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  def init(_) do
    if ChatOverlay.Persistence.backend() == :postgres do
      :ok = ChatOverlay.Postgres.validate_runtime!()
      document = ChatOverlay.Postgres.export!()
      Application.put_env(:chat_overlay, :profiles, document["profiles"])
      Application.put_env(:chat_overlay, :media_objects, document["media_objects"])
    end

    {:ok, _} = ChatOverlay.Config.validate(ChatOverlay.Config.profiles())
    true = ChatOverlay.MediaLedger.valid?(Application.get_env(:chat_overlay, :media_objects, []))
    {:ok, nil}
  end
end
