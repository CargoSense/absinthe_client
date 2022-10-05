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
  alias AbsintheClient.WebSocket.{Push, Reply}
  alias Req.Request

  @type graphql :: String.t() | {String.t(), nil | map()}

  @type web_socket :: GenServer.server()

  @default_receive_timeout 15_000

  @default_socket_url "/socket/websocket"

  @doc """
  Dynamically starts (or re-uses already started) AbsintheWs
  process with the given options:

    * `:url` - URL where to make the WebSocket connection. When
      provided as an option to `connect/2` the request's `base_url`
      will be prepended to this path. The default value is
      `"/socket/websocket"`.

    * `:headers` - list of headers to send on the initial
      HTTP request. Defaults to `[]`.

    * `:connect_options` - list of options given to
      `Mint.HTTP.connect/4` for the initial HTTP request:

        * `:timeout` - socket connect timeout in milliseconds,
          defaults to `30_000`.

    * `:connect_params` - Optional. Custom params to be sent when the
      WebSocket connects. Defaults to sending the bearer Authorization
      token if one is present on the request. The default value is `nil`.

    * `:parent` - pid of the process starting the connection.
      The socket monitors this process and shuts down when
      the parent process exits. Defaults to `self()`.

  Note that when `connect/2` returns successfully, it indicates that
  the WebSocket process has started. The process must then connect
  to the GraphQL server and join the relevant topic(s) before it can
  send and receive messages.

  ## Examples

  From a request:

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach()
      iex> {:ok, ws} = req |> AbsintheClient.WebSocket.connect()
      iex> ws |> GenServer.whereis() |> Process.alive?()
      true

  From keyword options:

      iex> {:ok, ws} = AbsintheClient.WebSocket.connect(url: "ws://localhost:4002/socket/websocket")
      iex> ws |> GenServer.whereis() |> Process.alive?()
      true
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
      iex> ws |> GenServer.whereis() |> Process.alive?()
      true

  With a custom URL path:

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach()
      iex> {:ok, ws} = req |> AbsintheClient.WebSocket.connect(url: "/socket/websocket")
      iex> ws |> GenServer.whereis() |> Process.alive?()
      true
  """
  @spec connect(Request.t(), keyword) :: {:ok, web_socket()} | {:error, Exception.t()}
  def connect(%Request{} = request, options) when is_list(options) do
    {parent, options} = Keyword.split(options, [:parent])

    %{request | adapter: &run_ws_options/1}
    |> Request.register_options([:parent])
    |> Request.merge_options(parent)
    |> Req.request([url: @default_socket_url] ++ options)
    |> case do
      {:ok, %{body: socket}} -> {:ok, socket}
      {:error, _} = error -> error
    end
  end

  defp run_ws_options(%Request{} = req) do
    parent = Map.get(req.options, :parent, self())

    req = update_in(req.url.scheme, &String.replace(&1, "http", "ws"))
    req = put_connect_params(req)
    mint_options = Map.get(req.options, :connect_options, [])

    config_options = [
      uri: req.url,
      headers: req.headers,
      mint_opts: [
        protocols: [:http1],
        transport_opts: [timeout: mint_options[:timeout] || 30_000]
      ]
    ]

    case Slipstream.Configuration.validate(config_options) do
      {:ok, _config} ->
        name = custom_socket_name([parent: parent] ++ config_options)

        case DynamicSupervisor.start_child(
               AbsintheClient.SocketSupervisor,
               {AbsintheClient.WebSocket.AbsintheWs, {parent, config_options, [name: name]}}
             ) do
          {:ok, _} ->
            {req, Req.Response.new(body: name)}

          {:error, {:already_started, _}} ->
            {req, Req.Response.new(body: name)}
        end

      {:error, _} = error ->
        {req, error}
    end
  end

  defp put_connect_params(%Request{} = req) do
    case Map.fetch(req.options, :connect_params) do
      {:ok, params} ->
        put_connect_params(req, params)

      :error ->
        maybe_put_auth_params(req)
    end
  end

  defp put_connect_params(%Request{} = req, params) do
    encoded = URI.encode_query(params)

    update_in(req.url.query, fn
      nil -> encoded
      query -> query <> "&" <> encoded
    end)
  end

  defp maybe_put_auth_params(%Request{} = req) do
    case Map.fetch(req.options, :auth) do
      {:ok, {:bearer, token}} ->
        put_connect_params(req, %{"Authorization" => "Bearer #{token}"})

      _ ->
        req
    end
  end

  @doc """
  Same as `connect/1` but raises on error.

  ## Examples

  From a request:

      iex> ws = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.WebSocket.connect!()
      iex> ws |> GenServer.whereis() |> Process.alive?()
      true

  From keyword options:

      iex> ws = AbsintheClient.WebSocket.connect!(url: "ws://localhost:4002/socket/websocket")
      iex> ws |> GenServer.whereis() |> Process.alive?()
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
      iex> ws |> GenServer.whereis() |> Process.alive?()
      true
  """
  @spec connect!(Request.t(), keyword) :: web_socket()
  def connect!(request, options) do
    case connect(request, options) do
      {:ok, req} -> req
      {:error, exception} -> raise exception
    end
  end

  defp custom_socket_name(options) do
    name =
      options
      |> :erlang.term_to_binary()
      |> :erlang.md5()
      |> Base.url_encode64(padding: false)

    Module.concat(AbsintheClient.SocketSupervisor, "Socket_#{name}")
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

    send(socket, %Push{
      event: "doc",
      params: params,
      pid: self(),
      ref: ref = make_ref()
    })

    ref
  end

  @doc """
  Awaits the server's response to a pushed document.

  ## Examples

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach(async: true)
      iex> {:ok, ws} = AbsintheClient.WebSocket.connect(req)
      iex> {:ok, res} = Req.request(req, web_socket: ws, graphql: ~S|{ __type(name: "Repo") { name } }|)
      iex> {:ok, reply} = AbsintheClient.WebSocket.await_reply(res)
      iex> reply.payload["data"]
      %{"__type" => %{"name" => "Repo"}}
  """
  @spec await_reply(Req.Response.t() | reference(), non_neg_integer()) ::
          {:ok, AbsintheClient.WebSocket.Reply.t()} | {:error, :timeout}
  def await_reply(response_or_ref, timeout \\ 5000)

  def await_reply(%Req.Response{body: ref}, timeout) when is_reference(ref) do
    await_reply(ref, timeout)
  end

  def await_reply(ref, timeout) when is_reference(ref) do
    receive do
      %Reply{ref: ^ref} = reply ->
        {:ok, reply}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  defp await_reply(%Request{} = req, ref, receive_timeout) do
    case await_reply(ref, receive_timeout) do
      {:ok, reply} -> {req, reply_response(req, reply)}
      {:error, reason} -> {req, reason}
    end
  end

  @doc """
  Awaits the server's response to a pushed document or raises an error.

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
      {:error, :timeout} -> raise RuntimeError, "timeout"
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
