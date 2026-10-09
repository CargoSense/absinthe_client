defmodule AbsintheClient.WebSocket do
  @moduledoc """
  `Req` adapter for Absinthe subscriptions.

  The WebSocket does the following:

    * Pushes documents to the GraphQL server and forwards
      replies to the callers.

    * Manages any subscriptions received, including
      automatically re-subscribing in the event of a
      connection loss.

  Under the hood, WebSocket connections are `Slipstream`
  socket processes which are usually managed by an internal
  AbsintheClient supervisor.

  ## Examples

  Performing a `query` operation over a WebSocket:

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach()
      iex> ws = req |> AbsintheClient.WebSocket.connect!()
      iex> Req.request!(req, web_socket: ws, graphql: ~S|{ __type(name: "Repo") { name } }|).body["data"]
      %{"__type" => %{"name" => "Repo"}}

  Performing an async `query` operation and awaiting the reply:

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach()
      iex> ws = req |> AbsintheClient.WebSocket.connect!()
      iex> reply =
      ...>   req
      ...>   |> Req.request!(web_socket: ws, async: true, graphql: ~S|{ __type(name: "Repo") { name } }|)
      ...>   |> AbsintheClient.WebSocket.await_reply!()
      iex> reply.payload["data"]
      %{"__type" => %{"name" => "Repo"}}

  ## Handling messages

  Subscription results are sent to the process that created the
  subscription as [`WebSocket.Message`](`AbsintheClient.WebSocket.Message`)
  structs, and the socket sends [`WebSocket.Closed`](`AbsintheClient.WebSocket.Closed`)
  when it stops or a subscription is gone.

  In a `GenServer` for instance, you would implement
  [`handle_info/2`](`c:GenServer.handle_info/2`) callbacks:

      def handle_info(%AbsintheClient.WebSocket.Message{ref: ref, payload: payload}, state) do
        # A result for the subscription created by the push with this ref.
        {:noreply, state}
      end

      def handle_info(%AbsintheClient.WebSocket.Closed{ref: nil}, state) do
        # The socket stopped. Call connect/2 again.
        {:noreply, state}
      end

      def handle_info(%AbsintheClient.WebSocket.Closed{ref: ref}, state) do
        # The subscription with this ref is gone. Push the document again.
        {:noreply, state}
      end

  """
  alias AbsintheClient.Utils
  alias AbsintheClient.WebSocket.{AbsintheWs, Closed, Config, Op, Push, Reply, Timeout}
  alias Req.Request

  @type graphql :: String.t() | {String.t(), nil | map()}

  @type web_socket :: pid()

  @default_receive_timeout 15_000

  @default_socket_url "/socket/websocket"

  @doc """
  Starts a WebSocket process, or re-uses the one already running for
  this process and URL, and returns its pid.

  The socket is identified by the parent process, the URL, and the
  transport options. Credentials are not part of the identity, so
  connecting again with new credentials re-uses the running socket
  and the socket adopts the new request on its next reconnect. A
  second `connect/2` from the same parent to the same URL with any
  other difference, such as another `:max_rejections` or header,
  returns `{:error, %ArgumentError{}}`, because the running socket
  cannot change them.

  When `connect/2` returns `{:ok, pid}` the socket process is running
  and its first connection attempt has been made. The socket connects
  to the server and joins the control topic on its own, and documents
  pushed before then wait for it.

  ## Options

    * `:url` - URL where to make the WebSocket connection. When
      provided as an option to `connect/2` the request's `base_url`
      will be prepended to this path. The default value is
      `"/socket/websocket"`.

    * `:headers` - headers to send on the initial
      HTTP request. Defaults to `[]`.

    * `:connect_options` - list of options given to
      `Mint.HTTP.connect/4` for the initial HTTP request:

        * `:timeout` - socket connect timeout in milliseconds,
          defaults to `30_000`.

        * `:transport_opts` - keyword list of options passed to the
          underlying transport layer (SSL/TCP). Common options include:

            * `:verify` - `:verify_peer` or `:verify_none` for SSL verification
            * `:cacertfile` - path to CA certificate file
            * `:certfile` - path to client certificate for mTLS
            * `:keyfile` - path to client private key for mTLS
            * `:versions` - list of allowed TLS versions (e.g., `[:"tlsv1.2", :"tlsv1.3"]`)
            * `:nodelay` - boolean to disable Nagle's algorithm for lower latency
            * `:timeout` - connection timeout (defaults to `30_000` if not specified)

          See the [Erlang :ssl module documentation](https://www.erlang.org/doc/man/ssl.html)
          for a complete list of available options.

    * `:connect_params` - Optional. Custom params to be sent when the
      WebSocket connects, as a map or a zero-arity function that
      returns a map. Defaults to sending the bearer Authorization
      token if one is present on the request. The default value is `nil`.

    * `:max_rejections` - Optional. The number of times the server may
      reject the connection, without a successful connection in
      between, before the socket stops. Defaults to `5`. Refer to the
      Reconnecting section for what counts as a rejection.

    * `:reconnect` - Optional. Whether to reconnect after a disconnect.
      `true` (default) retries as described in the Reconnecting
      section. `false` stops the socket on the first disconnect of any
      kind, the same as `retry: false` for `Req.Steps.retry/1`. A
      function receives the disconnect reason and returns a boolean.

    * `:reconnect_delay` - Optional. The time in milliseconds to wait
      before a reconnect attempt, or a function that receives the
      number of attempts since the last successful connection (starting
      at `0`) and returns it, the same as `:retry_delay` for
      `Req.Steps.retry/1`. Refer to the Reconnecting section for the
      default.

    * `:parent` - pid of the process starting the connection.
      The socket monitors this process and shuts down when
      the parent process exits. Defaults to `self()`.

  ## Token refresh

  The socket runs the request steps again before every connection
  attempt, so a zero-arity function given to `:auth` or
  `:connect_params` is called each time the socket connects or
  reconnects:

      req =
        Req.new(
          base_url: "https://example.com",
          auth: fn -> {:bearer, MyApp.Token.fetch!()} end
        )
        |> AbsintheClient.attach()

      {:ok, ws} = AbsintheClient.WebSocket.connect(req)

  The function runs inside the socket process, on the first connection
  and on every reconnect, and never for an operation sent over the
  socket. It must read the token from a shared place such as an
  `Agent`, an ETS table, or a token server. It must not call into the
  parent process: `connect/2` waits for the first attempt, and later
  the parent may be waiting on the socket while the socket waits on the
  function. A raise in the function counts as a rejected connection and
  is logged with its stacktrace.

  ## Reconnecting

  A dropped connection, a refused or timed-out transport, a 5xx
  response, and the transient 408 and 429 responses reconnect with
  Slipstream's backoff for as long as the parent process lives. A
  `Retry-After` header on a 429 or 503 response sets the delay instead.

  A rejected connection, that is any other HTTP 4xx status on the
  upgrade request or a request step that raises, reconnects with the
  same exponential backoff with jitter as the `Req.Steps.retry/1` step:
  about 1s, 2s, 4s, 8s and so on. After `:max_rejections` rejections
  without a successful connection in between, the socket stops.

  Each failed upgrade logs a warning with the delay before the next
  attempt. `:reconnect_delay` overrides the delay for every reconnect.

  Set `reconnect: false` to stop on the first disconnect instead, or
  pass a function to decide per disconnect reason. The function
  receives the reason as Slipstream reports it, for example `:closed`
  when the server closed the connection or
  `{:error, {:upgrade_failure, %{status_code: 401}}}` when it refused
  the upgrade:

      AbsintheClient.WebSocket.connect(req,
        reconnect: fn
          {:error, {:upgrade_failure, %{status_code: 401}}} -> false
          _reason -> true
        end
      )

  ## When the socket stops

  When the socket gives up, it sends an `AbsintheClient.WebSocket.Closed`
  message with a `nil` ref to the parent process and one with the
  subscription ref to the owner of each active subscription, returns
  the same `Closed` struct as the error of every pending operation,
  and exits. It does the same when it crashes. Only a kill from outside
  or a stop of the `:absinthe_client` application ends a socket without
  a `Closed`. Calling `connect/2` again starts a new socket.

  When the socket gives up on its first attempt, because
  `:max_rejections` is `1` or `:reconnect` is `false`, `connect/2`
  returns `{:error, exception}` instead and no `Closed` is sent.

  A document that is in flight when the connection drops gets a
  `Closed` with the reason `{:disconnected, reason}` at once. The socket
  stays alive and reconnects, and the document can be pushed again.
  Active subscriptions are re-subscribed after the reconnect.

  ## Examples

  From a request:

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach()
      iex> {:ok, ws} = req |> AbsintheClient.WebSocket.connect()
      iex> Process.alive?(ws)
      true

  From keyword options:

      iex> {:ok, ws} = AbsintheClient.WebSocket.connect(url: "ws://localhost:4002/socket/websocket")
      iex> Process.alive?(ws)
      true

  Disabling SSL verification for local development:

      iex> req = Req.new(base_url: "https://localhost:4002") |> AbsintheClient.attach()
      iex> {:ok, ws} = req |> AbsintheClient.WebSocket.connect(
      ...>   connect_options: [transport_opts: [verify: :verify_none]]
      ...> )
      iex> Process.alive?(ws)
      true

  Using client certificates for mTLS:

      req = Req.new(base_url: "https://example.com") |> AbsintheClient.attach()

      {:ok, ws} = req |> AbsintheClient.WebSocket.connect(
        connect_options: [
          transport_opts: [
            verify: :verify_peer,
            cacertfile: "/path/to/ca.pem",
            certfile: "/path/to/client-cert.pem",
            keyfile: "/path/to/client-key.pem"
          ]
        ]
      )

      Process.alive?(ws)
      # ==> true
  """
  @spec connect(request_or_options :: Request.t() | keyword) ::
          {:ok, web_socket()} | {:error, Exception.t()}
  def connect(request_or_options)

  def connect(%Req.Request{} = request) do
    connect(request, [])
  end

  def connect(options) when is_list(options) do
    connect(AbsintheClient.attach(Req.new()), options)
  end

  @doc """
  Connects to an Absinthe WebSocket.

  Refer to `connect/1` for more information.

  ### Examples

  With the default URL path:

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach()
      iex> {:ok, ws} = req |> AbsintheClient.WebSocket.connect()
      iex> Process.alive?(ws)
      true

  With a custom URL path:

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach()
      iex> {:ok, ws} = req |> AbsintheClient.WebSocket.connect(url: "/socket/websocket")
      iex> Process.alive?(ws)
      true
  """
  @spec connect(Request.t(), keyword) :: {:ok, web_socket()} | {:error, Exception.t()}
  def connect(%Request{} = request, options) when is_list(options) do
    request =
      request
      |> Request.register_options([:parent, :max_rejections, :reconnect_delay, :reconnect])
      |> Req.merge([url: @default_socket_url] ++ options)

    parent = Map.get(request.options, :parent, self())

    with {:ok, config} <- Config.build(request, credentials: false) do
      start_socket(parent, request, config)
    end
  end

  defp start_socket(parent, %Request{} = request, %Config{} = config) do
    # The settings a running socket cannot change are kept as the Registry
    # value, so a second connect/2 can compare them without asking the socket.
    settings = settings(config)
    name = {:via, Registry, {AbsintheClient.SocketRegistry, {parent, config.key}, settings}}

    child_spec =
      {AbsintheWs,
       parent: parent,
       request: request,
       max_rejections: config.max_rejections,
       reconnect_delay: config.reconnect_delay,
       reconnect: config.reconnect,
       name: name}

    case DynamicSupervisor.start_child(AbsintheClient.SocketSupervisor, child_spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        case Registry.lookup(AbsintheClient.SocketRegistry, {parent, config.key}) do
          [{^pid, ^settings}] ->
            send(pid, {:update_request, request})
            {:ok, pid}

          [{^pid, running}] ->
            {:error, settings_error(running, settings)}

          # The socket stopped in between, so the next connect/2 starts a new one.
          _ ->
            start_socket(parent, request, config)
        end

      # The socket gave up on its first attempt, so the build error is returned.
      {:error, {:shutdown, {:closed, {:request_failed, exception}}}} ->
        {:error, exception}

      {:error, %{__exception__: true} = exception} ->
        {:error, exception}

      {:error, reason} ->
        {:error, %RuntimeError{message: "failed to start WebSocket, got: #{inspect(reason)}"}}
    end
  end

  defp settings(%Config{} = config) do
    %{
      headers: config.slipstream[:headers],
      mint_opts: config.slipstream[:mint_opts],
      max_rejections: config.max_rejections,
      reconnect: config.reconnect,
      reconnect_delay: config.reconnect_delay
    }
  end

  defp settings_error(running, requested) do
    differing =
      for {key, value} <- requested, running[key] != value, do: key

    %ArgumentError{
      message:
        "a WebSocket for this process and URL is already running with different " <>
          Enum.map_join(differing, ", ", &inspect/1) <>
          ". Only the credentials can change on a second connect; " <>
          "use another parent process for a socket with other options"
    }
  end

  @doc """
  Same as `connect/1` but raises on error.

  ## Examples

  From a request:

      iex> ws = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.WebSocket.connect!()
      iex> Process.alive?(ws)
      true

  From keyword options:

      iex> ws = AbsintheClient.WebSocket.connect!(url: "ws://localhost:4002/socket/websocket")
      iex> Process.alive?(ws)
      true
  """
  @spec connect!(request_or_options :: Request.t() | keyword) :: web_socket()
  def connect!(request_or_options) do
    case connect(request_or_options) do
      {:ok, ws} -> ws
      {:error, error} -> raise error
    end
  end

  @doc """
  Same as `connect/2` but raises on error.

  ## Examples

      iex> ws =
      ...>  Req.new(base_url: "http://localhost:4002")
      ...>  |> AbsintheClient.WebSocket.connect!(url: "/socket/websocket")
      iex> Process.alive?(ws)
      true
  """
  @spec connect!(Request.t(), keyword) :: web_socket()
  def connect!(request, options) do
    case connect(request, options) do
      {:ok, req} -> req
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Performs a GraphQL operation.

  ## Examples

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach()
      iex> ws = req |> AbsintheClient.WebSocket.connect!()
      iex> Req.request!(req, web_socket: ws, graphql: ~S|{ __type(name: "Repo") { name } }|).body["data"]
      %{"__type" => %{"name" => "Repo"}}
  """
  @spec run(Request.t()) :: {Request.t(), Req.Response.t() | Exception.t()}
  def run(%Request{} = request) do
    receive_timeout = Map.get(request.options, :receive_timeout, @default_receive_timeout)
    push = push(request.options.web_socket, request.options.graphql)

    case Map.fetch(request.options, :async) do
      {:ok, true} -> {request, Req.Response.new(body: push)}
      {:ok, false} -> await_reply(request, push, receive_timeout)
      :error -> await_reply(request, push, receive_timeout)
    end
  end

  defp reply_response(%Request{} = req, %Reply{} = reply) do
    Req.Response.new(
      status: ws_response_status(reply.status),
      body: ws_response_body(req, reply),
      private: %{ws_push_ref: reply.push_ref}
    )
  end

  defp ws_response_status(:ok), do: 200
  defp ws_response_status(:error), do: 500

  defp ws_response_body(_req, %{payload: payload}), do: payload

  @doc """
  Pushes a document to the server via the given `socket`.

  Returns an `AbsintheClient.WebSocket.Push` to pass to `await_reply/2`.
  The server's reply arrives as an `AbsintheClient.WebSocket.Reply`
  message with the push's ref. If the socket stops first, the caller
  receives an `AbsintheClient.WebSocket.Closed` with that ref instead,
  and `await_reply/2` returns either one.

  ## Examples

      iex> {:ok, ws} = AbsintheClient.WebSocket.connect(url: "ws://localhost:4002/socket/websocket")
      iex> push = AbsintheClient.WebSocket.push(ws, ~S|{ __type(name: "Repo") { name } }|)
      iex> AbsintheClient.WebSocket.await_reply!(push).payload["data"]
      %{"__type" => %{"name" => "Repo"}}
  """
  @spec push(request_or_socket :: Request.t() | web_socket(), graphql()) :: Push.t()
  def push(request_or_socket, graphql)

  def push(%Request{} = req, graphql) do
    socket = Map.fetch!(req.options, :web_socket)
    push(socket, graphql)
  end

  def push(socket, graphql) do
    params = Utils.request_json!(graphql)

    # The push ref is a monitor with a reply alias. The reply removes the
    # monitor, so only a socket that exits before it replies sends a DOWN.
    ref = Process.monitor(socket, alias: :reply_demonitor)
    send(socket, %Op{event: "doc", params: params, pid: self(), ref: ref})

    %Push{socket: socket, ref: ref}
  end

  @doc """
  Awaits the server's response to a pushed document.

  Returns `{:error, %AbsintheClient.WebSocket.Timeout{}}` when the
  server does not reply within `timeout`, and
  `{:error, %AbsintheClient.WebSocket.Closed{}}` when the socket stops
  before the server replies or had already stopped.

  After a timeout the push is cancelled: a reply that arrives later is
  discarded, and if that reply created a subscription the socket
  unsubscribes it at once, so no data is ever delivered for it.

  ## Examples

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach(async: true)
      iex> {:ok, ws} = AbsintheClient.WebSocket.connect(req)
      iex> {:ok, res} = Req.request(req, web_socket: ws, graphql: ~S|{ __type(name: "Repo") { name } }|)
      iex> {:ok, reply} = AbsintheClient.WebSocket.await_reply(res)
      iex> reply.payload["data"]
      %{"__type" => %{"name" => "Repo"}}
  """
  @spec await_reply(Push.t() | Req.Response.t(), non_neg_integer()) ::
          {:ok, AbsintheClient.WebSocket.Reply.t()} | {:error, Timeout.t() | Closed.t()}
  def await_reply(push_or_response, timeout \\ 5000)

  def await_reply(%Req.Response{body: %Push{} = push}, timeout) do
    await_reply(push, timeout)
  end

  def await_reply(%Push{socket: socket, ref: ref}, timeout) do
    receive do
      %Reply{ref: ^ref} = reply ->
        {:ok, reply}

      # A closing socket sends Closed to the push ref, which is a reply alias.
      %Closed{ref: ^ref} = closed ->
        {:error, closed}

      {:DOWN, ^ref, :process, socket, reason} ->
        {:error, Closed.from_exit(socket, ref, reason)}
    after
      timeout ->
        # Removing the monitor also removes the alias, so a late reply is
        # dropped. A reply that slipped into the mailbox first is removed
        # too, and the socket undoes whatever the push achieved.
        Process.demonitor(ref, [:flush])
        flush_reply(ref)
        send(socket, {:cancel, ref})
        {:error, %Timeout{ref: ref, timeout: timeout}}
    end
  end

  defp flush_reply(ref) do
    receive do
      %Reply{ref: ^ref} -> :ok
    after
      0 -> :ok
    end
  end

  defp await_reply(%Request{} = req, push, receive_timeout) do
    case await_reply(push, receive_timeout) do
      {:ok, reply} -> {req, reply_response(req, reply)}
      {:error, exception} -> {req, exception}
    end
  end

  @doc """
  Awaits the server's response to a pushed document or raises an error.

  Raises `AbsintheClient.WebSocket.Timeout` when the server does not
  reply within `timeout`, and `AbsintheClient.WebSocket.Closed` when the
  socket stops before the server replies.

  ## Examples

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach(async: true)
      iex> ws = req |> AbsintheClient.WebSocket.connect!()
      iex> res = Req.post!(req, web_socket: ws, graphql: ~S|{ __type(name: "Repo") { name } }|)
      iex> AbsintheClient.WebSocket.await_reply!(res).payload["data"]
      %{"__type" => %{"name" => "Repo"}}
  """
  @spec await_reply!(Push.t() | Req.Response.t(), non_neg_integer()) ::
          AbsintheClient.WebSocket.Reply.t()
  def await_reply!(push_or_response, timeout \\ 5000)

  def await_reply!(%Req.Response{body: %Push{} = push}, timeout) do
    await_reply!(push, timeout)
  end

  def await_reply!(%Push{} = push, timeout) do
    case await_reply(push, timeout) do
      {:ok, reply} -> reply
      {:error, exception} -> raise exception
    end
  end

  # Clears all subscriptions on the given socket.
  @doc false
  @spec clear_subscriptions(web_socket) :: :ok
  @spec clear_subscriptions(web_socket, ref_or_nil :: nil | reference()) :: :ok
  def clear_subscriptions(ws, ref \\ nil) when is_nil(ref) or is_reference(ref) do
    send(ws, {:clear_subscriptions, self(), ref})
    :ok
  end
end
