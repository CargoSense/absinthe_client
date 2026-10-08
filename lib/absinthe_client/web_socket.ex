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

  Results will be sent to the caller as
  [`WebSocket.Message`](`AbsintheClient.WebSocket.Message`) structs.

  In a `GenServer` for instance, you would implement a
  [`handle_info/2`](`c:GenServer.handle_info/2`) callback:

      def handle_info(%AbsintheClient.WebSocket.Message{payload: payload}, state) do
        # code...
        {:noreply, state}
      end

  """
  alias AbsintheClient.Utils
  alias AbsintheClient.WebSocket.{AbsintheWs, Config, Push, Reply}
  alias Req.Request

  @type graphql :: String.t() | {String.t(), nil | map()}

  @type web_socket :: pid()

  @default_receive_timeout 15_000

  @default_socket_url "/socket/websocket"

  @doc """
  Dynamically starts (or re-uses already started) AbsintheWs
  process with the given options.

  The socket is identified by the parent process, the URL, and the
  transport options. Credentials are not part of the identity, so
  connecting again with new credentials re-uses the running socket
  and the socket adopts the new request on its next reconnect.

  Options:

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

    * `:max_rejections` - Optional. The number of consecutive times the
      server may reject the connection (HTTP 4xx on upgrade, except
      408 and 429) before the
      socket stops. Defaults to `5`. Refer to the Token refresh section
      for more information.

    * `:reconnect_delay` - Optional. The time in milliseconds to wait
      before a reconnect attempt, or a function that receives the
      number of consecutive attempts (starting at `0`) and returns it,
      the same as `:retry_delay` for `Req.Steps.retry/1`. By default a
      transport failure follows Slipstream's backoff and a rejected
      connection follows exponential backoff with jitter. Refer to the
      Token refresh section for more information.

    * `:reconnect` - Optional. Whether to reconnect after a disconnect.
      `true` (default) retries as described in the Token refresh
      section. `false` stops the socket on the first disconnect of any
      kind, the same as `retry: false` for `Req.Steps.retry/1`. A
      function receives the disconnect reason and returns a boolean.

    * `:parent` - pid of the process starting the connection.
      The socket monitors this process and shuts down when
      the parent process exits. Defaults to `self()`.

  Note that when `connect/2` returns successfully, it indicates that
  the WebSocket process has started. The process must then connect
  to the GraphQL server and join the relevant topic(s) before it can
  send and receive messages.

  ## Token refresh

  The socket re-runs the request steps before every connection
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

  The function always runs inside the socket process, on the first
  connection as well as on every reconnect, and never for an operation
  sent over the socket. It must read the token
  from a shared place such as an `Agent`, an ETS table, or a token
  server. It must not call into the parent process: `connect/2` waits
  for the first attempt, and later the parent may be waiting on the
  socket while the socket waits on the function. A raise in the
  function counts as a rejected connection and is logged with its
  stacktrace. When the socket gives up on the first attempt, because
  `:max_rejections` is `1` or `:reconnect` is `false`, `connect/2`
  returns `{:error, exception}` instead.

  Transport failures, 5xx responses, and the transient 408 and 429
  responses retry with Slipstream's backoff until the parent process
  exits. A rejected connection, that is any other HTTP 4xx status on
  the upgrade request or a request step that raises, retries with the
  same backoff as the `Req.Steps.retry/1` step: about 1s, 2s, 4s, 8s
  and so on, with jitter. A `Retry-After` header on a 429 or 503
  response sets the delay instead. Each failed upgrade logs a
  warning. After
  `:max_rejections` rejections in a row the socket sends an
  `AbsintheClient.WebSocket.Closed` message to the parent and to each
  subscriber, returns `{:error, {:closed, reason}}` from
  `await_reply/2` for any pending operation, and stops. Calling
  `connect/2` again starts a new socket. The socket sends the same
  `Closed` message when it crashes. Only a kill from outside or a stop
  of the `:absinthe_client` application ends a socket without one.

  Set `reconnect: false` to stop on the first disconnect instead, or
  pass a function to decide per disconnect reason:

      AbsintheClient.WebSocket.connect(req,
        reconnect: fn
          {:error, {:upgrade_failure, %{status_code: 401}}} -> false
          _reason -> true
        end
      )

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
    name = {:via, Registry, {AbsintheClient.SocketRegistry, {parent, config.key}}}

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
        send(pid, {:update_request, request})
        {:ok, pid}

      # The socket gave up on its first attempt, so the build error is returned.
      {:error, {:shutdown, {:closed, {:error, %{__exception__: true} = exception}}}} ->
        {:error, exception}

      {:error, %{__exception__: true} = exception} ->
        {:error, exception}

      {:error, reason} ->
        {:error, %RuntimeError{message: "failed to start WebSocket, got: #{inspect(reason)}"}}
    end
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
    ref = push(request.options.web_socket, request.options.graphql)

    case Map.fetch(request.options, :async) do
      {:ok, true} -> {request, Req.Response.new(body: ref)}
      {:ok, false} -> await_reply(request, ref, receive_timeout)
      :error -> await_reply(request, ref, receive_timeout)
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
  Pushes a `query` to the server via the given `socket`.

  Returns a reference to pass to `await_reply/2`. The reference is also
  a monitor on the socket. The reply removes the monitor. If the socket
  exits before it replies, the caller receives a
  `{:DOWN, ref, :process, socket, reason}` message instead, which
  `await_reply/2` returns as `{:error, {:closed, reason}}`.

  ## Examples

      iex> {:ok, req} = AbsintheClient.WebSocket.connect(url: "ws://localhost:4002/socket/websocket")
      iex> ref = AbsintheClient.WebSocket.push(req, ~S|{ __type(name: "Repo") { name } }|)
      iex> AbsintheClient.WebSocket.await_reply!(ref).payload["data"]
      %{"__type" => %{"name" => "Repo"}}
  """
  @spec push(request_or_socket :: Request.t() | web_socket(), graphql()) :: reference()
  def push(request_or_socket, graphql)

  def push(%Request{} = req, graphql) do
    socket = Map.fetch!(req.options, :web_socket)
    push(socket, graphql)
  end

  def push(socket, graphql) do
    params = Utils.request_json!(graphql)

    # The push ref is a monitor with a reply alias. The reply removes the
    # monitor, so only a socket that exits before it replies sends a DOWN.
    send(socket, %Push{
      event: "doc",
      params: params,
      pid: self(),
      ref: ref = Process.monitor(socket, alias: :reply_demonitor)
    })

    ref
  end

  @doc """
  Awaits the server's response to a pushed document.

  Returns `{:error, :timeout}` when the server does not reply within
  `timeout`, and `{:error, {:closed, reason}}` when the socket stops
  before the server replies. When the socket gives up after repeated
  rejections, `reason` is the final disconnect reason. When the socket
  had already exited, `reason` is its exit reason. A reply that arrives
  after the timeout is discarded.

  ## Examples

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach(async: true)
      iex> {:ok, ws} = AbsintheClient.WebSocket.connect(req)
      iex> {:ok, res} = Req.request(req, web_socket: ws, graphql: ~S|{ __type(name: "Repo") { name } }|)
      iex> {:ok, reply} = AbsintheClient.WebSocket.await_reply(res)
      iex> reply.payload["data"]
      %{"__type" => %{"name" => "Repo"}}
  """
  @spec await_reply(Req.Response.t() | reference(), non_neg_integer()) ::
          {:ok, AbsintheClient.WebSocket.Reply.t()} | {:error, :timeout | {:closed, term()}}
  def await_reply(response_or_ref, timeout \\ 5000)

  def await_reply(%Req.Response{body: ref}, timeout) when is_reference(ref) do
    await_reply(ref, timeout)
  end

  def await_reply(ref, timeout) when is_reference(ref) do
    receive do
      # Only a closing socket replies without a push ref. Return the same
      # error as for a socket that is already down.
      %Reply{ref: ^ref, status: :error, push_ref: nil, payload: reason} ->
        {:error, {:closed, reason}}

      %Reply{ref: ^ref} = reply ->
        {:ok, reply}

      {:DOWN, ^ref, :process, _, reason} ->
        {:error, {:closed, reason}}
    after
      timeout ->
        # Removing the monitor also removes the alias, so a late reply is dropped.
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  defp await_reply(%Request{} = req, ref, receive_timeout) do
    case await_reply(ref, receive_timeout) do
      {:ok, reply} ->
        {req, reply_response(req, reply)}

      {:error, reason} ->
        {req, %AbsintheClient.WebSocket.Error{reason: reason}}
    end
  end

  @doc """
  Awaits the server's response to a pushed document or raises an error.

  Raises `AbsintheClient.WebSocket.Error` when the server does not reply
  within `timeout` or the socket stops before the server replies.

  ## Examples

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach(async: true)
      iex> ws = req |> AbsintheClient.WebSocket.connect!()
      iex> res = Req.post!(req, web_socket: ws, graphql: ~S|{ __type(name: "Repo") { name } }|)
      iex> AbsintheClient.WebSocket.await_reply!(res).payload["data"]
      %{"__type" => %{"name" => "Repo"}}
  """
  @spec await_reply!(Req.Response.t() | reference(), non_neg_integer()) ::
          AbsintheClient.WebSocket.Reply.t()
  def await_reply!(response_or_ref, timeout \\ 5000)

  def await_reply!(%Req.Response{body: ref}, timeout) when is_reference(ref) do
    await_reply!(ref, timeout)
  end

  def await_reply!(ref, timeout) when is_reference(ref) do
    case await_reply(ref, timeout) do
      {:ok, reply} -> reply
      {:error, reason} -> raise AbsintheClient.WebSocket.Error, reason: reason
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
