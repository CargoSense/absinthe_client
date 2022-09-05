defmodule AbsintheClient.Steps do
  @moduledoc """
  The collection of built-in steps.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the `Req` plugin for GraphQL

    * `AbsintheClient.Steps` - the collection of built-in steps (you're here!)

    * `AbsintheClient.WebSocket` - the `Absinthe` WebSocket subscription manager

  """

  @doc """
  Encodes the GraphQL operation.

  ## Request Options

    * `:query` - Required. A GraphQL document with a single
      operation.

    * `:variables` - An optional map of input values.

  ## Examples

      iex> client = AbsintheClient.attach(Req.new(url: "https://rickandmortyapi.com/graphql"))
      iex> Req.post!(client, query: "query{ character(id: 1){ name } }").body["data"]
      %{"character" => %{"name" => "Rick Sanchez"}}

      iex> client = AbsintheClient.attach(Req.new(url: "https://rickandmortyapi.com/graphql"))
      iex> Req.post!(client,
      ...>   query: "query($id: ID!){ character(id: $id){ name } }",
      ...>   variables: %{id: 2}
      ...> ).body["data"]
      %{"character" => %{"name" => "Morty Smith"}}
  """
  @doc step: :request
  def encode_operation(%Req.Request{} = request) do
    query = Map.fetch!(request.options, :query)
    variables = Map.get(request.options, :variables, %{})

    encode_operation(request, request.method, query, variables)
  end

  defp encode_operation(request, :post, query, variables) do
    encode_json(request, %{query: query, variables: variables})
  end

  defp encode_operation(request, AbsintheClient.WebSocket, query, variables) do
    encode_json(request, %{query: query, variables: variables})
  end

  # remove once we support :get request formatting
  defp encode_operation(_request, method, _query, _variables) do
    raise ArgumentError,
          "invalid request method, expected :post, got: #{inspect(method)}"
  end

  defp encode_json(request, body) do
    %{request | body: Jason.encode_to_iodata!(body)}
    |> Req.Request.put_new_header("content-type", "application/json")
    |> Req.Request.put_new_header("accept", "application/json")
  end

  @doc """
  Overrides the Req adapter for subscription requests.

  If set, the adapter is overriden with
  `run_absinthe_ws_adapter/1`.

  """
  @doc step: :request
  def put_ws_adapter(%Req.Request{} = request) do
    case Map.fetch(request.options, :ws_adapter) do
      :error ->
        %Req.Request{request | adapter: &run_absinthe_ws_adapter/1}

      {:ok, true} ->
        %Req.Request{request | adapter: &run_absinthe_ws_adapter/1}

      {:ok, false} ->
        request
    end
  end

  @doc """
  Runs the request using `AbsintheClient.WebSocket`.

  This is the default WebSocket adapter for AbsintheClient
  set via the `AbsintheClient.Steps.put_ws_adapter/1` step.

  While you _can_ use `AbsintheClient.WebSocket` to execute
  all your operation types, it is recommended to continue
  using HTTP for queries and mutations. This is because
  queries and mutations are not stateful so they are more
  suited to HTTP and will scale better there in most cases.

  The `AbsintheClient.Steps.put_ws_adapter/1` step
  introspects the operation type to override the adapter
  when it encounters a `:subscription` operation type.

  ## Examples

      req = Req.new(adapter: &AbsintheClient.Steps.run_absinthe_ws_adapter/1)

  """
  @doc step: :adapter
  def run_absinthe_ws_adapter(%Req.Request{} = request) do
    socket_name = AbsintheClient.connect(self(), request)

    query = Map.fetch!(request.options, :query)
    variables = Map.get(request.options, :variables, %{})
    ref = Map.get(request.options, :ws_reply_ref, nil)

    case AbsintheClient.WebSocket.push_sync(socket_name, query, variables, ref) do
      {:error, %{__exception__: true} = exception} ->
        {request, exception}

      {:ok, payload} ->
        {request,
         Req.Response.new(body: %{"data" => payload}, private: %{AbsintheClient.WebSocket => ref})}
    end
  end
end
