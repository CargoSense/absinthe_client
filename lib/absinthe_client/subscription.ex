defmodule AbsintheClient.Subscription do
  @moduledoc """
  A subscription the server created for a pushed document.

  It is the `:payload` of the `AbsintheClient.WebSocket.Reply` to the
  document, and the body of the `Req.request/2` response. Results then
  arrive as `AbsintheClient.WebSocket.Message` structs with the same
  ref.

  ## Fields

    * `:socket` - The pid of the WebSocket process.

    * `:ref` - The ref of the `AbsintheClient.WebSocket.Push` that
      created the subscription.

    * `:id` - The subscription id the server assigned.

  """
  @type t :: %__MODULE__{
          socket: pid(),
          ref: reference(),
          id: String.t()
        }
  defstruct [:socket, :ref, :id]
end
