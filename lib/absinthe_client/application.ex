defmodule AbsintheClient.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AbsintheClient.SocketRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: AbsintheClient.SocketSupervisor}
    ]

    # Registered sockets are linked to their Registry partition, so they
    # exit together with the Registry and nothing is left unregistered.
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
