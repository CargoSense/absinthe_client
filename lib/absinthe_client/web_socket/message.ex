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

defmodule AbsintheClient.WebSocket.Closed do
  @moduledoc """
  Message sent when the WebSocket stops after the server repeatedly
  rejects the connection, or after any disconnect when reconnecting is
  disabled with `reconnect: false`.

  The socket sends one message per active subscription to the process
  that created it, and one message with a `nil` ref to the parent
  process.

  The message format requires the following keys:

    * `:socket` - The pid of the WebSocket process.

    * `:ref` - The subscription ref, or `nil` for the parent notification.

    * `:reason` - The reason of the final disconnect.

  """
  @type t :: %__MODULE__{}
  defstruct [:socket, :ref, :reason]
end

defmodule AbsintheClient.WebSocket.Error do
  @moduledoc """
  Error returned when a pushed document gets no reply.

  `Req.request/2` returns this exception in its error tuple, and
  `AbsintheClient.WebSocket.await_reply!/2` raises it.

  The `:reason` is one of:

    * `:timeout` - The server did not reply within the receive timeout.

    * `{:closed, reason}` - The socket stopped before the server replied.
      When the socket gives up after repeated rejections, the inner
      reason is the final disconnect reason, for example
      `{:error, {:upgrade_failure, %{status_code: 403}}}`. When the
      socket had already exited, it is the exit reason of the socket
      process, for example `:noproc`.

  """
  defexception [:reason]

  @type t :: %__MODULE__{reason: :timeout | {:closed, term()}}

  @impl true
  def message(%{reason: :timeout}), do: "timed out waiting for a reply from the WebSocket"

  def message(%{reason: {:closed, reason}}),
    do: "the WebSocket exited before it replied, got: #{inspect(reason)}"
end
