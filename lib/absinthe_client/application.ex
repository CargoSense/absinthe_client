defmodule AbsintheClient.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AbsintheClient.SocketRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: AbsintheClient.SocketSupervisor}
    ]

    # Sockets outlive a crashed Registry, so a restart must take them down too.
    Supervisor.start_link(children, strategy: :rest_for_one)
  end
end
