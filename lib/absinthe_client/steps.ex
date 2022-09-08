defmodule AbsintheClient.Steps do
  @moduledoc """
  The collection of `Req` steps.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the Absinthe client for GraphQL

    * `AbsintheClient.Steps` - the collection of `Req` steps (you're here!)

    * `AbsintheClient.WebSocket` - the `Absinthe` WebSocket connection

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

  defp encode_operation(request, method, query, variables) do
    if request.options[:ws_adapter] do
      encode_json(request, %{query: query, variables: variables})
    else
      # remove once we support :get request formatting
      raise ArgumentError,
            "invalid request method, expected :post, got: #{inspect(method)}"
    end
  end

  defp encode_json(request, body) do
    %{request | body: Jason.encode_to_iodata!(body)}
    |> Req.Request.put_new_header("content-type", "application/json")
    |> Req.Request.put_new_header("accept", "application/json")
  end

  @doc """
  Puts the GraphQL path on the URI.

  ## Request options

    * `:ws_adapter` - If set to `true`, then the request path
      defaults to `"/socket/websocket"`. Defaults to `false`.

    * `:url` - If set, the path to set on the request.
      Defaults to `"/graphql"`.
  """
  @doc step: :request
  def put_graphql_path(%Req.Request{} = request) do
    cond do
      _ = request.url.path ->
        request

      _ = request.options[:ws_adapter] ->
        put_in(request.url.path, "/socket/websocket")

      true ->
        put_in(request.url.path, "/graphql")
    end
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

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"), ws_adapter: true)
      iex> AbsintheClient.run!(client, ~S|{ __type(name: "Repo") { name } }|).body["data"]
      %{"__type" => %{"name" => "Repo"}}
  """
  @doc step: :request
  def put_ws_scheme(%Req.Request{} = request) do
    case Map.fetch(request.options, :ws_adapter) do
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

  ## Retries

  Note that due to the asynchronous nature of the WebSocket
  connection process, by default this function will retry the
  message if an `AbsintheClient.NotJoinedError` is returned.

  Consult the `Req.request/1` retry options for more information.

  ## Examples

      req = Req.new(adapter: &AbsintheClient.Steps.run_absinthe_ws_adapter/1)

  """
  @doc step: :request
  def run_absinthe_ws_adapter(%Req.Request{} = request) do
    socket_name = AbsintheClient.WebSocket.connect(self(), request.url)
    request = Req.Request.put_private(request, :absinthe_client_ws, socket_name)

    query = Map.fetch!(request.options, :query)
    variables = Map.get(request.options, :variables, %{})

    {:ok, ref} = AbsintheClient.WebSocket.push(socket_name, query, variables)

    if Map.get(request.options, :ws_async) do
      {request, Req.Response.new(private: %{ws_async_ref: ref})}
    else
      receive_timeout = Map.get(request.options, :receive_timeout, 15_000)

      case AbsintheClient.WebSocket.await_reply(ref, receive_timeout) do
        {:ok, reply} ->
          {request, reply_response(request, reply)}

        {:error, reason} ->
          {request, reason}
      end
    end
  end

  defp reply_response(%Req.Request{} = req, %AbsintheClient.WebSocket.Reply{} = reply) do
    Req.Response.new(
      status: ws_response_status(reply.status),
      body: ws_response_body(req, reply),
      private: %{
        ws_async_ref: reply.ref,
        ws_push_ref: reply.push_ref
      }
    )
  end

  defp ws_response_status(:ok), do: 200
  defp ws_response_status(:error), do: 500

  defp ws_response_body(req, reply) do
    case reply do
      %{status: :ok, payload: %{"subscriptionId" => subscription_id}} ->
        %AbsintheClient.Subscription{
          socket: req.private.absinthe_client_ws,
          ref: reply.ref,
          id: subscription_id
        }

      _ ->
        reply.payload
    end
  end
end
