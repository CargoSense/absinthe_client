defmodule AbsintheClient.WebSocket.Reply do
  @moduledoc """
  Reply sent from GraphQL servers to clients in response to a pushed document.

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
  Message sent from the server to the client.

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
  @type t :: %__MODULE__{}
  defstruct [:event, :pid, :params, :ref, pushed_counter: 0]

  @doc """
  Returns a new push message.

  ## Examples

      iex> AbsintheClient.WebSocket.Push.new()
      %AbsintheClient.WebSocket.Push{}

      iex> AbsintheClient.WebSocket.Push.new(event: "foo")
      %AbsintheClient.WebSocket.Push{event: "foo"}
  """
  @spec new(options :: keyword()) :: t()
  def new(options \\ []) do
    struct!(__MODULE__, options)
  end
end
