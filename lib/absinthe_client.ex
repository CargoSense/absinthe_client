defmodule AbsintheClient do
  @moduledoc ~S"""
  The Absinthe client for GraphQL.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the Absinthe client for GraphQL (you're here!)

    * `AbsintheClient.Steps` - the collection of `Req` steps

    * `AbsintheClient.WebSocket` - the `Absinthe` WebSocket connection

  The following examples demonstrate how most users of AbsintheClient will
  make GraphQL requests most of the time.

  ## Examples

  Performing a `query` operation:

      iex> client = AbsintheClient.attach(Req.new(base_url: "https://rickandmortyapi.com"))
      iex> AbsintheClient.run!(client, "query { character(id: 1) { name } }").body["data"]
      %{"character" => %{"name" => "Rick Sanchez"}}

  Performing a `query` operation with variables:

      iex> client = AbsintheClient.attach(Req.new(url: "https://rickandmortyapi.com"))
      iex> AbsintheClient.run!(client, "query($id: ID!) { character(id: $id) { name } }",
      ...>   variables: %{id: 3}
      ...> ).body["data"]
      %{"character" => %{"name" => "Summer Smith"}}

  Overriding the default path:

      iex> client = AbsintheClient.attach(Req.new(base_url: "https://graphqlzero.almansi.me"))
      iex> AbsintheClient.run!(
      ...>   client,
      ...>   "mutation($input: CreatePostInput!){ createPost(input: $input){ body title }}",
      ...>   url: "/api",
      ...>   variables: %{
      ...>     "input" => %{
      ...>       "title" => "My New Post",
      ...>       "body" => "This is the post body."
      ...>     }
      ...>   }
      ...> ).body["data"]
      %{"createPost" => %{"body" => "This is the post body.", "title" => "My New Post"}}

  ## Subscriptions

  > #### Absinthe subscriptions required! {: .tip}
  >
  > AbsintheClient works with servers using
  > [Absinthe subscriptions](https://hexdocs.pm/absinthe/subscriptions.html).

  Performing a `subscription` operation:

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"))
      iex> AbsintheClient.subscribe!(
      ...>   client,
      ...>   "subscription($repository: Repository!){ repoCommentSubscribe(repository: $repository){ id commentary } }",
      ...>   variables: %{"repository" => "ELIXIR"}
      ...> ).body.__struct__
      AbsintheClient.Subscription

  Receiving the subscription data, for example on a `GenServer`:

      def handle_info(%AbsintheClient.WebSocket.Message{event: "subscription:data", payload: payload}, state) do
        case payload["result"] do
          %{"errors" => errors} ->
            raise "Received result with errors, got: #{inspect(result["errors"])}"

          %{"data" => data} ->
            text = get_in(result, ~w(data repoCommentSubscribe commentary))
            IO.inspect(text, label: "Received a new comment")
        end

        {:noreply, state}
      end
  """

  @doc """
  Attaches the `AbsintheClient` steps to a given `request`.

  ## Options

  Operation options:

    * `:query` - A string of a GraphQL document with a single
      operation.

    * `:variables` - A map of input values for the operation.

  WebSocket options:

    * `:web_socket` - the WebSocket process to use. Defaults
      to a socket automatically started by `AbsintheClient`.

    * `:receive_timeout` - socket receive timeout in milliseconds,
      defaults to `15_000`.

    * `:ws_adapter` - When set to `true`, runs the operation
      via the WebSocket adapter. Defaults to `false`.

    * `:ws_async` - When set to `true`, runs the operation
      in async mode. The response body will be empty and you
      will need to receive the `AbsintheClient.WebSocket.Reply`
      message. Defaults to `false`.

  AbsintheWs options (`run_absinthe_ws` step):

    * `:connect_options` - dynamically starts (or re-uses already
      started) AbsintheWs socket with the given connection options:

        * `:timeout` - socket connect timeout in milliseconds, defaults to 30_000.

  ## Examples

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://example.com"))
      iex> client.method
      :post

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://example.com"), ws_adapter: true)
      iex> client.method
      :post

  """
  @spec attach(Req.Request.t(), keyword) :: Req.Request.t()
  def attach(%Req.Request{} = request, options \\ []) do
    # todo: remove when we support :get requests
    %{request | method: :post}
    |> Req.Request.register_options([:query, :variables, :web_socket, :ws_adapter, :ws_async])
    |> Req.Request.merge_options(options)
    |> Req.Request.append_request_steps(
      encode_operation: &AbsintheClient.Steps.encode_operation/1,
      put_ws_scheme: &AbsintheClient.Steps.put_ws_scheme/1,
      put_ws_adapter: &AbsintheClient.Steps.put_ws_adapter/1,
      put_graphql_path: &AbsintheClient.Steps.put_graphql_path/1
    )
  end

  @doc """
  Performs a `subscription` operation.

  Note this operation must be performed by the WebSocket
  adapter.

  Refer to `attach/2` for a list of supported options.

  ## Examples

  Synchronous subscription:

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"))
      iex> response = AbsintheClient.subscribe!(
      ...>   client,
      ...>   "subscription($repository: Repository!){ repoCommentSubscribe(repository: $repository){ id commentary } }",
      ...>   variables: %{"repository" => "ELIXIR"}
      ...> )
      iex> is_struct(response.body, AbsintheClient.Subscription)
      true

  Asynchronous subscription:

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"))
      iex> response = AbsintheClient.subscribe!(
      ...>   client,
      ...>   "subscription($repository: Repository!){ repoCommentSubscribe(repository: $repository){ id commentary } }",
      ...>   variables: %{"repository" => "ELIXIR"},
      ...>   ws_async: true
      ...> )
      iex> is_reference(response.body)
      true

  """
  @spec subscribe!(Req.Request.t(), String.t(), keyword) :: Req.Response.t()
  def subscribe!(request, subscription, options \\ [])

  def subscribe!(%Req.Request{} = request, subscription, options) do
    {ws_async, options} = Keyword.split(options, [:ws_async])
    request = Req.Request.merge_options(request, ws_async)
    response = run!(request, subscription, options ++ [ws_adapter: true])

    if Map.get(request.options, :ws_async) do
      response
    else
      case response.body do
        %AbsintheClient.Subscription{} ->
          response

        other ->
          raise ArgumentError,
                "unexpected response from subscribe!/3, " <>
                  "expected AbsintheClient.Subscription.t(), " <>
                  "got: #{inspect(other)}"
      end
    end
  end

  @doc """
  Runs a GraphQL operation and returns a response.

  Refer to `attach/2` for a list of supported options.

  All other options are forwarded to `Req.request/2`.

  ## Examples

  HTTP request:

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"))
      iex> {:ok, response} = AbsintheClient.run(client, "query{}")
      iex> response.body["errors"]
      [%{"locations" => [%{"column" => 7, "line" => 1}], "message" => "syntax error before: '}'"}]

  WebSocket request:

      iex> client = AbsintheClient.attach(Req.new(base_url: "ws://localhost:8001"))
      iex> {:ok, response} = AbsintheClient.run(client, "query{}", ws_adapter: true)
      iex> response.body["errors"]
      [%{"locations" => [%{"column" => 7, "line" => 1}], "message" => "syntax error before: '}'"}]

  """
  @spec run(Req.Request.t(), String.t(), keyword) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def run(request, operation, options \\ []) do
    # todo: remove :method once we support :get requests
    Req.request(request, [method: :post, query: operation] ++ options)
  end

  @doc """
  Runs a GraphQL operation and returns a response or raises an error.

  Refer to `attach/2` for a list of supported options.

  ## Examples

      iex> client = AbsintheClient.attach(Req.new(url: "https://rickandmortyapi.com"))
      iex> AbsintheClient.run!(client, "query($id: ID!) { character(id: $id) { name } }",
      ...>   variables: %{id: 5}
      ...> ).body["data"]
      %{"character" => %{"name" => "Jerry Smith"}}
  """
  @spec run!(Req.Request.t(), String.t(), keyword) :: Req.Response.t()
  def run!(request, operation, options \\ []) do
    case run(request, operation, options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end
end
