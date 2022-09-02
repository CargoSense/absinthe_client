defmodule AbsintheClient.Request do
  @moduledoc """
  The `Req` plugin with subscription adapter.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the high-level API

    * `AbsintheClient.Request` - the `Req` plugin with subscription adapter (you're here!)

    * `AbsintheClient.WebSocket` - the `Absinthe` WebSocket subscription manager

  The plugin comprises the individual steps required
  to perform a GraphQL operation via a [`Request`](`Req.Request`).
  The plugin supports subscriptions by overriding the request
  adapter for subscription operations with a socket-based
  implementation with built-in state management.

  ## The plugin

  Most queries can be performed like this:

      AbsintheClient.query!(url, query: "query { allLinks { url } }").data
      #=> %{ "allLinks" => %{ "url" => "http://graphql.org/" } }

  If you want to compose AbsintheClient into an existing
  request pipeline, you can add the plugin:

      query = "query { allLinks { url } }"

      req =
        Req.new(method: :post, url: url)
        |> AbsintheClient.Request.attach(query: query)

      AbsintheClient.Request.run!(req).data
      #=> %{ "allLinks" => %{ "url" => "http://graphql.org/" } }

  """

  @doc """
  Attaches the `AbsintheClient` steps to a given `request`.

  ## Examples

      iex> req = Req.new(method: :post, url: "ws://localhost")
      iex> req = AbsintheClient.Request.attach(req, operation: "query{}")
      iex> req.options.operation
      "query{}"

  """
  @spec attach(Req.Request.t(), keyword) :: Req.Request.t()
  def attach(%Req.Request{} = request, options \\ []) do
    request
    |> Req.Request.register_options([:operation])
    |> Req.Request.merge_options(options)
    |> Req.Request.prepend_request_steps(
      put_encode_operation: &AbsintheClient.Request.put_encode_operation/1,
      put_ws_adapter: &AbsintheClient.Request.put_ws_adapter/1
    )
    |> Req.Request.append_response_steps(
      put_response_operation: &AbsintheClient.Request.put_response_operation/1
    )
  end

  @doc """
  Makes an `AbsintheClient.Operation` for the request and encodes it.
  """
  def put_encode_operation(%Req.Request{} = request) do
    # remove once we support :get request formatting
    unless request.method == :post do
      raise ArgumentError,
            "only :post requests are currently supported, got: #{inspect(request.method)}"
    end

    with {:ok, operation} <- Map.fetch(request.options, :operation) do
      req_with_operation =
        case operation do
          # "query ($id: ID!) { allLinks(id: $id) { url } }"
          doc when is_binary(doc) ->
            put_operation(request, {:query, doc, nil})

          # {"query ($id: ID!) { allLinks(id: $id) { url } }", %{id: 1}}
          {doc, vars} when is_binary(doc) and is_map(vars) ->
            put_operation(request, {:query, doc, vars})

          # {:query, "query { allLinks { url }}"}
          {kind, doc}
          when kind in [:query, :mutation, :subscription] and
                 is_binary(doc) ->
            put_operation(request, {kind, doc, nil})

          # {:query, {"query ($id: ID!) { allLinks(id: $id) { url } }", %{id: 1}}}
          {kind, {doc, vars}}
          when kind in [:query, :mutation, :subscription] and
                 is_binary(doc) and is_map(vars) ->
            put_operation(request, {kind, doc, vars})

          # {:query, "query ($id: ID!) { allLinks(id: $id) { url } }", %{id: 1}}
          {kind, doc, vars} = operation
          when kind in [:query, :mutation, :subscription] and
                 is_binary(doc) and is_map(vars) ->
            put_operation(request, operation)
        end

      # todo: add support for :get request formatting
      %{req_with_operation | body: Jason.encode_to_iodata!(req_with_operation.private.operation)}
      |> Req.Request.put_new_header("content-type", "application/json")
      |> Req.Request.put_new_header("accept", "application/json")
    else
      _ -> raise KeyError, key: :operation, term: request.options
    end
  end

  defp put_operation(%Req.Request{} = req, {op_type, doc, variables}) do
    Req.Request.put_private(
      req,
      :operation,
      %AbsintheClient.Operation{
        owner: self(),
        operation_type: op_type,
        query: doc,
        variables: variables
      }
    )
  end

  @doc """
  Copies the operation from the request to the response.
  """
  def put_response_operation({%Req.Request{} = request, %Req.Response{} = response}) do
    {request, Req.Response.put_private(response, :operation, request.private.operation)}
  end

  @doc """
  Overrides the Req adapter for subscription requests.

  See `run_absinthe_ws_adapter/1`.

  """
  def put_ws_adapter(%Req.Request{} = request) do
    case Req.Request.get_private(request, :operation) do
      %AbsintheClient.Operation{operation_type: :subscription} ->
        %Req.Request{request | adapter: &run_absinthe_ws_adapter/1}

      _ ->
        request
    end
  end

  @doc """
  Runs the request using `AbsintheClient.WebSocket`.

  This is the default WebSocket adapter for AbsintheClient
  set via the `AbsintheClient.Request.put_ws_adapter/1` step.

  While you _can_ use `AbsintheClient.WebSocket` to execute
  all your operation types, it is recommended to continue
  using HTTP for queries and mutations. This is because
  queries and mutations are not stateful so they are more
  suited to HTTP and will scale better there in most cases.

  The `AbsintheClient.Request.put_ws_adapter/1` step
  introspects the operation type to override the adapter
  when it encounters a `:subscription` operation type.

  ## Examples

      req = Req.new(adapter: &AbsintheClient.run_absinthe_ws_adapter/1)

  """
  def run_absinthe_ws_adapter(%Req.Request{} = request) do
    operation = request.private.operation
    socket_name = AbsintheClient.Request.start_socket(operation.owner, request)

    operation_ref = make_ref()
    operation = %AbsintheClient.Operation{operation | ref: operation_ref}
    new_request = Req.Request.put_private(request, :operation, operation)

    case AbsintheClient.WebSocket.push_sync(socket_name, operation) do
      {:error, %{__exception__: true} = exception} ->
        {new_request, exception}

      {:ok, payload} ->
        {new_request, Req.Response.new(body: %{"data" => payload})}
    end
  end

  @doc """
  Starts a socket process for the caller and the given `request`.

  Usually you do not need to invoke this function directly,
  since it is automatically invoked by the high-level
  [`subscribe!/2`](`AbsintheClient.subscribe!/2`) function.
  However in certain cases you may want to start the socket
  process early.

  ## Examples

      iex> url = AbsintheClientTest.Endpoint.subscription_url()
      iex> client = AbsintheClient.new(url: url)
      iex> socket_name = AbsintheClient.Request.start_socket(client)
      iex> is_atom(socket_name)
      true

  """
  @spec start_socket(request :: Req.Request.t()) :: atom()
  @spec start_socket(owner :: pid(), request :: Req.Request.t()) :: atom()
  def start_socket(owner \\ self(), %Req.Request{} = request) do
    name = custom_socket_name(owner: owner, url: request.url)

    case DynamicSupervisor.start_child(
           AbsintheClient.SocketSupervisor,
           {AbsintheClient.WebSocket, {owner, name: name, uri: request.url}}
         ) do
      {:ok, _} ->
        name

      {:error, {:already_started, _}} ->
        name
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
end
