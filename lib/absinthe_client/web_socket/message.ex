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

defmodule AbsintheClient.WebSocket.Op do
  # Internal structure to track pushed operations inside the socket.
  @moduledoc false
  @type t :: %__MODULE__{}
  defstruct [:event, :pid, :params, :ref, pushed_counter: 0, cancelled: false]

  @doc """
  Returns a new operation.

  ## Examples

      iex> AbsintheClient.WebSocket.Op.new()
      %AbsintheClient.WebSocket.Op{}

      iex> AbsintheClient.WebSocket.Op.new(event: "foo")
      %AbsintheClient.WebSocket.Op{event: "foo"}
  """
  @spec new(options :: keyword()) :: t()
  def new(options \\ []) do
    struct!(__MODULE__, options)
  end
end

defmodule AbsintheClient.WebSocket.Push do
  @moduledoc """
  A document pushed to the WebSocket.

  `AbsintheClient.WebSocket.push/2` returns it, and so does
  `Req.request/2` with `async: true` in the response body. Pass it to
  `AbsintheClient.WebSocket.await_reply/2`.

  ## Fields

    * `:socket` - The pid of the WebSocket process.

    * `:ref` - The ref of the push. The `AbsintheClient.WebSocket.Reply`
      to it, the `AbsintheClient.Subscription` it creates, every
      `AbsintheClient.WebSocket.Message` for that subscription, and an
      `AbsintheClient.WebSocket.Closed` about it carry the same ref.

  """
  @type t :: %__MODULE__{socket: pid(), ref: reference()}
  defstruct [:socket, :ref]
end

defmodule AbsintheClient.WebSocket.Closed do
  @moduledoc """
  The WebSocket stopped, or an operation on it is gone.

  With a `nil` ref the socket itself stopped. It sends this message to
  the parent process when it stops on its own: after the server
  repeatedly rejects the connection, after any disconnect when
  reconnecting is disabled with `reconnect: false`, or when the socket
  crashes. It is not sent when the socket is killed from outside or
  when the `:absinthe_client` application stops.

  With a ref the operation with that ref is gone. The socket sends one
  message per active subscription to the process that created it when
  the socket stops, and one per document that was in flight when the
  connection dropped, with the reason `{:disconnected, reason}`. In the
  second case the socket is still alive and reconnecting, so the
  document can be pushed again.

  The same struct is the error of an operation that got no reply:
  `AbsintheClient.WebSocket.await_reply/2` and `Req.request/2` return it
  in their error tuple, and `AbsintheClient.WebSocket.await_reply!/2`
  raises it.

  ## Fields

    * `:socket` - The pid of the WebSocket process.

    * `:ref` - The ref of the subscription or of the awaited push, or
      `nil` for the parent notification.

    * `:reason` - Why the socket stopped or the operation is gone:

        * `{:rejected, %Req.Response{}}` - The server refused the
          connection `:max_rejections` times in a row. The response
          holds the status and the headers of the last attempt.

        * `{:request_failed, exception}` - The request could not be
          built, for example because the `:auth` function raised.

        * `{:disconnected, reason}` - The connection dropped. The inner
          reason says why: `:closed` when the server closed it,
          `:heartbeat_timeout`, `{:send_failure, reason}`, a transport
          error atom such as `:econnreset`, or a `Mint.TransportError`
          when a connection attempt failed. For a push, the document
          was in flight when the connection dropped and the socket is
          reconnecting. For the parent, reconnecting is disabled and the
          socket stopped.

        * `:noproc` - The socket had already stopped when the document
          was pushed.

        * `:shutdown` - The parent process exited.

        * `{:crashed, reason}` - The socket crashed with the given exit
          reason.

  """
  defexception [:socket, :ref, :reason]

  @type reason ::
          {:rejected, Req.Response.t()}
          | {:request_failed, Exception.t()}
          | {:disconnected, term()}
          | :noproc
          | :shutdown
          | {:crashed, term()}

  @type t :: %__MODULE__{socket: pid(), ref: reference() | nil, reason: reason()}

  @impl true
  def message(%{socket: socket, reason: reason}) do
    "the WebSocket #{inspect(socket)} closed: #{describe(reason)}"
  end

  defp describe({:rejected, %Req.Response{status: status}}),
    do: "the server rejected the connection with status #{status}"

  defp describe({:request_failed, exception}),
    do: "the request could not be built: " <> Exception.message(exception)

  defp describe({:disconnected, reason}), do: "the connection dropped, got: #{inspect(reason)}"
  defp describe(:noproc), do: "the socket had already stopped"
  defp describe(:shutdown), do: "the parent process exited"
  defp describe({:crashed, reason}), do: "the socket crashed, got: #{inspect(reason)}"

  @doc false
  @spec from_exit(pid(), reference() | nil, term()) :: t()
  def from_exit(socket, ref, exit_reason) do
    %__MODULE__{socket: socket, ref: ref, reason: reason_from_exit(exit_reason)}
  end

  # The socket exits with the Closed reason inside its exit reason, so a
  # monitor and a Closed message agree.
  @doc false
  @spec reason_from_exit(term()) :: reason()
  def reason_from_exit({:shutdown, {:closed, reason}}), do: reason
  def reason_from_exit(:noproc), do: :noproc
  def reason_from_exit(:shutdown), do: :shutdown
  def reason_from_exit(reason), do: {:crashed, reason}
end

defmodule AbsintheClient.WebSocket.Timeout do
  @moduledoc """
  The server did not reply to a pushed document in time.

  `AbsintheClient.WebSocket.await_reply/2` and `Req.request/2` return
  it in their error tuple, and `AbsintheClient.WebSocket.await_reply!/2`
  raises it. A reply that arrives later is discarded.

  ## Fields

    * `:ref` - The ref of the awaited push.

    * `:timeout` - The time waited, in milliseconds.

  """
  defexception [:ref, :timeout]

  @type t :: %__MODULE__{ref: reference(), timeout: non_neg_integer()}

  @impl true
  def message(%{timeout: timeout}), do: "no reply from the WebSocket within #{timeout}ms"
end
