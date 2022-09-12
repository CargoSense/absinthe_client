defmodule AbsintheClient.WebSocket do
  @moduledoc """
  The `Absinthe` WebSocket subscription manager.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the Absinthe client for GraphQL

    * `AbsintheClient.Steps` - the collection of `Req` steps

    * `AbsintheClient.WebSocket` - the `Absinthe` WebSocket connection (you're here!)

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

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"), ws_adapter: true)
      iex> AbsintheClient.run!(client, ~S|{ __type(name: "Repo") { name } }|).body["data"]
      %{"__type" => %{"name" => "Repo"}}

  Performing an async `query` operation and awaiting the reply:

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"), ws_adapter: true, ws_async: true)
      iex> response = AbsintheClient.run!(client, ~S|{ __type(name: "Repo") { name } }|)
      iex> AbsintheClient.WebSocket.await_reply!(response).payload["data"]
      %{"__type" => %{"name" => "Repo"}}

  ## Handling messages

  Results will be sent to the caller in the form of
  [`WebSocket.Message`](`AbsintheClient.WebSocket.Message`) structs.

  In a `GenServer` for instance, you would implement a
  [`handle_info/2`](`c:GenServer.handle_info/2`) callback:

      def handle_info(%AbsintheClient.WebSocket.Message{payload: payload}, state) do
        # code...
        {:noreply, state}
      end

  """
  alias AbsintheClient.WebSocket.{Push, Reply}

  @doc """
  Dynamically starts (or re-uses already started) AbsintheWs
  process with the given options:

    * `:url` - URL where to make the WebSocket connection.

    * `:headers` - list of headers to send on the initial
      HTTP request. Defaults to `[]`.

    * `:connect_options` - list of options given to
      `Mint.HTTP.connect/4` for the initial HTTP request:

        * `:timeout` - socket connect timeout in milliseconds,
          defaults to `30_000`.

    * `:parent` - pid of the process starting the connection.
      The socket monitors this process and shuts down when
      the parent process exits. Defaults to `self()`.

  Note that this function returning succcessfully merely
  indicate that the WebSocket process has started. The
  process must then connect to the GraphQL server and join
  the relevant topic(s) before it can begin sending and
  receiving messages.

  Note also if you are using `connect/1` in conjunction with
  high-level `AbsintheClient` functions, you must ensure the
  options match those given by the `run_absinthe_ws` step
  otherwise you may start more processes that necessary.

  ## Examples

  From a request:

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"), ws_adapter: true)
      iex> {:ok, ws} = AbsintheClient.WebSocket.connect(client)
      iex> ws |> GenServer.whereis() |> Process.alive?()
      true

  From keyword options:

      iex> {:ok, ws} = AbsintheClient.WebSocket.connect(url: "ws://localhost:8001/socket/websocket")
      iex> ws |> GenServer.whereis() |> Process.alive?()
      true
  """
  @spec connect(request_or_options :: Req.Request.t() | Keyword.t()) ::
          {:ok, atom()} | {:error, reason :: term()}
  def connect(%Req.Request{} = request) do
    options =
      Req.request!(request,
        # query is required by AbsintheClient– it is empty because we are not making an actual request.
        query: "",
        # this funky adapter _just_ returns the final form of the socket options
        # as the response body..
        ws_adapter: fn req ->
          {req,
           Req.Response.new(
             body: [url: req.url, headers: req.headers] ++ :maps.to_list(req.options)
           )}
        end
      ).body

    connect(options)
  end

  def connect(options) do
    {url, options} = Keyword.pop!(options, :url)
    {headers, options} = Keyword.pop(options, :headers, [])
    {parent, options} = Keyword.pop(options, :parent, self())
    {mint_options, _options} = Keyword.pop(options, :connect_options, [])

    config_options = [
      uri: url,
      headers: headers,
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
            {:ok, name}

          {:error, {:already_started, _}} ->
            {:ok, name}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Same as `connect/1` but raises on error.

  ## Examples

  From a request:

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"), ws_adapter: true)
      iex> ws = AbsintheClient.WebSocket.connect!(client)
      iex> ws |> GenServer.whereis() |> Process.alive?()
      true

  From keyword options:

      iex> ws = AbsintheClient.WebSocket.connect!(url: "ws://localhost:8001/socket/websocket")
      iex> ws |> GenServer.whereis() |> Process.alive?()
      true
  """
  @spec connect!(request_or_options :: Req.Request.t() | Keyword.t()) :: atom()
  def connect!(request_or_options) do
    case connect(request_or_options) do
      {:ok, name} -> name
      {:error, error} -> raise error
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
  Pushes a `query` to the server via the given `socket`.

  ## Examples

      iex> {:ok, ws} = AbsintheClient.WebSocket.connect(url: "ws://localhost:8001/socket/websocket")
      iex> ref = AbsintheClient.WebSocket.push(ws, ~S|{ __type(name: "Repo") { name } }|)
      iex> AbsintheClient.WebSocket.await_reply!(ref).payload["data"]
      %{"__type" => %{"name" => "Repo"}}
  """
  @spec push(
          socket :: GenServer.server(),
          query :: String.t(),
          variables :: nil | keyword() | map()
        ) :: reference()
  def push(socket, query, variables \\ nil)
      when is_binary(query) and (is_nil(variables) or is_list(variables) or is_map(variables)) do
    send(socket, %Push{
      event: "doc",
      params: %{query: query, variables: variables},
      pid: self(),
      ref: ref = make_ref()
    })

    ref
  end

  @doc """
  Awaits the server's response to a pushed document.

  ## Examples

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"), ws_adapter: true, ws_async: true)
      iex> {:ok, response} = AbsintheClient.run(client, ~S|{ __type(name: "Repo") { name } }|)
      iex> {:ok, reply} = AbsintheClient.WebSocket.await_reply(response)
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

  @doc """
  Awaits the server's response to a pushed document or raises an error.

  ## Examples

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"), ws_adapter: true, ws_async: true)
      iex> response = AbsintheClient.run!(client, ~S|{ __type(name: "Repo") { name } }|)
      iex> AbsintheClient.WebSocket.await_reply!(response).payload["data"]
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
  @spec clear_subscriptions(socket :: GenServer.server()) :: :ok
  @spec clear_subscriptions(socket :: GenServer.server(), ref_or_nil :: nil | reference()) :: :ok
  def clear_subscriptions(socket, ref \\ nil) when is_nil(ref) or is_reference(ref) do
    send(socket, {:clear_subscriptions, self(), ref})
    :ok
  end
end
