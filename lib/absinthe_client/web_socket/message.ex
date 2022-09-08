defmodule AbsintheClient.WebSocket.Reply do
  @moduledoc """
  Defines a reply sent from GraphQL servers to clients.

  The message format requires the following keys:

    * `:event` - The string event name that was pushed, for example `"doc"`.

    * `:status` - The reply status as an atom.

    * `:payload` - The reply payload.

    * `:ref` - A unique term defined by the user when pushing or nil if none was provided.

    * `:push_ref` - The unique ref ref when pushing.

  """
  @type t :: %__MODULE__{}
  defstruct [:event, :status, :payload, :ref, :push_ref]
end

defmodule AbsintheClient.WebSocket.Message do
  @moduledoc """
  Defines a message from the from the server to the client.

  The message format requires the following keys:

    * `:topic` - The string topic.

    * `:event`- The string event name, for example `"subscription:data"`.

    * `:payload` - The message payload.

    * `:ref` - A unique term defined by the user when pushing or nil if none was provided.

    * `:push_ref` - The unique ref when pushing.

  """
  @type t :: %__MODULE__{}
  defstruct [:topic, :event, :payload, :ref, :push_ref]
end

defmodule AbsintheClient.WebSocket.Push do
  # Internal structure to track pushed requests.
  @moduledoc false
  defstruct [:event, :pid, :params, :ref]

  def new_doc(query, variables, pid, ref) do
    new("doc", %{query: query, variables: variables}, pid, ref)
  end

  def new(event, params, pid, ref) when is_binary(event) and is_map(params) and is_pid(pid) do
    %__MODULE__{
      event: event,
      params: params,
      pid: pid,
      ref: ref
    }
  end
end
