defmodule AbsintheClient.Subscription do
  @moduledoc """
  Structure returned when a subscription is created.
  """
  @type t :: %__MODULE__{
          socket: GenServer.server(),
          ref: term(),
          id: String.t()
        }
  defstruct [:socket, :ref, :id]
end
