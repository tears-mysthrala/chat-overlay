defmodule ChatOverlay.Application do
  @moduledoc "F1 supervision. Individual store/source failures stay in their own subtree."

  use Application

  @impl true
  def start(_type, _args) do
    case ChatOverlay.Custodian.Role.current() do
      :frontend ->
        :ok = ChatOverlay.Custodian.Role.assert_safe_frontend!()

        Supervisor.start_link([ChatOverlay.HTTP],
          strategy: :one_for_one,
          name: __MODULE__.Supervisor
        )

      role ->
        start_private(role)
    end
  end

  defp start_private(role) do
    case ChatOverlay.OAuth.validate_encryption_key() do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Invalid encryption key configuration: #{inspect(reason)}"
    end

    children =
      ChatOverlay.Persistence.children() ++
        [
          {Registry, keys: :unique, name: ChatOverlay.Registry},
          {Registry, keys: :duplicate, name: ChatOverlay.SSERegistry},
          # Headroom above the 30 supported sources for shutdown/relaunch churn.
          {Task.Supervisor, name: ChatOverlay.Tasks, max_children: 60}
        ] ++
        [
          ChatOverlay.Profiles,
          ChatOverlay.OAuthFlow,
          ChatOverlay.MediaCleanup,
          ChatOverlay.Tokens,
          ChatOverlay.Stores,
          ChatOverlay.Admission,
          ChatOverlay.WebhookGate
        ] ++
        [ChatOverlay.Sources] ++
        listener_children(role)

    Supervisor.start_link(children, strategy: :rest_for_one, name: __MODULE__.Supervisor)
  end

  defp listener_children(:custodian),
    do: [
      {ChatOverlay.Custodian.Listener, Application.fetch_env!(:chat_overlay, :custodian_listener)}
    ]

  defp listener_children(:combined),
    do: if(Application.get_env(:chat_overlay, :http), do: [ChatOverlay.HTTP], else: [])
end

defmodule ChatOverlay.Stores do
  @moduledoc false
  use Supervisor
  def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_),
    do:
      Supervisor.init(Enum.map(ChatOverlay.Config.profiles(), &ChatOverlay.Store.child_spec/1),
        strategy: :one_for_one
      )
end

defmodule ChatOverlay.Sources do
  @moduledoc false
  use Supervisor
  def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_),
    do:
      Supervisor.init(Enum.map(ChatOverlay.Config.sources(), &ChatOverlay.Source.child_spec/1),
        strategy: :one_for_one,
        max_restarts: 10
      )
end
