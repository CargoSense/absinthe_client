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
  Puts the GraphQL path on the URI.

  ## Request options

    * `:url` - If set, the path to set on the request.
      Defaults to `"/graphql"` for http schemes and
      `"/socket/websocket"` for ws schemes.
  """
  @doc step: :request
  def put_graphql_path(%Req.Request{} = request) do
    scheme = request.url.scheme

    update_in(request.url.path, fn
      nil ->
        cond do
          is_nil(scheme) -> nil
          String.starts_with?(scheme, "http") -> "/graphql"
          String.starts_with?(scheme, "ws") -> "/socket/websocket"
        end

      path ->
        path
    end)
  end

  @doc """
  Overrides the Req adapter for WebSocket requests.

  ## Request options

    * `:ws_adapter` - If set, to true, runs the request thru
      the `run_absinthe_ws_adapter/1`. Defaults to `false`.

  """
  @doc step: :request
  def put_ws_adapter(%Req.Request{} = request) do
    case Map.fetch(request.options, :ws_adapter) do
      {:ok, true} ->
        %Req.Request{request | adapter: &run_absinthe_ws_adapter/1}

      {:ok, false} ->
        request

      :error ->
        request
    end
  end

  @doc """
  Overrides the URI scheme for the WebSocket protocol.

  ## Examples

      iex> client = AbsintheClient.attach(Req.new(base_url: "https://rickandmortyapi.com"))
      iex> AbsintheClient.run!(client, "query { character(id: 1) { name } }").body["data"]
      %{"character" => %{"name" => "Rick Sanchez"}}
  """
  @doc step: :request
  def put_ws_scheme(%Req.Request{} = request) do
    case Map.fetch(request.options, :ws_scheme) do
      {:ok, true} -> put_ws_scheme(request, ws_scheme(request.url))
      {:ok, false} -> request
      :error -> request
    end
  end

  defp put_ws_scheme(request, scheme) when is_binary(scheme) do
    put_in(request.url.scheme, scheme)
  end

  defp ws_scheme(%URI{scheme: nil} = url), do: url

  defp ws_scheme(%URI{scheme: scheme} = url) when is_binary(scheme) do
    String.replace(url.scheme, "http", "ws")
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

  ## Examples

      req = Req.new(adapter: &AbsintheClient.Steps.run_absinthe_ws_adapter/1)

  """
  @doc step: :request
  def run_absinthe_ws_adapter(%Req.Request{} = request) do
    request = put_ws_scheme(request, ws_scheme(request.url))
    socket_name = AbsintheClient.WebSocket.connect(self(), request.url)
    request = Req.Request.put_private(request, :absinthe_client_ws, socket_name)

    query = Map.fetch!(request.options, :query)
    variables = Map.get(request.options, :variables, %{})
    ref = Map.get(request.options, :ws_reply_ref, nil)

    case AbsintheClient.WebSocket.push_sync(socket_name, query, variables, ref) do
      {:error, %{__exception__: true} = exception} ->
        {request, exception}

      {:ok, %AbsintheClient.WebSocket.Reply{} = reply} ->
        {request, Req.Response.new(body: transform_ws_reply(request, reply))}
    end
  end

  defp transform_ws_reply(%Req.Request{} = req, %AbsintheClient.WebSocket.Reply{} = reply) do
    case reply.result do
      {:ok, %{"subscriptionId" => subscription_id}} ->
        %AbsintheClient.Subscription{
          socket: req.private.absinthe_client_ws,
          ref: reply.ref,
          id: subscription_id
        }

      _ ->
        reply
    end
  end
end
