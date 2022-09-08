defmodule AbsintheClient do
  @moduledoc ~S"""
  The `Req` plugin for GraphQL.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the `Req` plugin for GraphQL (you're here!)

    * `AbsintheClient.Steps` - the collection of built-in steps

    * `AbsintheClient.WebSocket` - the `Absinthe` WebSocket subscription manager

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
  > Support for other GraphQL WebSocket protocols is not
  > planned.

  Performing a `subscription` operation:

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"))
      iex> subscription =
      ...>   AbsintheClient.subscribe!(
      ...>     client,
      ...>     "subscription($repository: Repository!){ repoCommentSubscribe(repository: $repository){ id commentary } }",
      ...>     variables: %{"repository" => "ELIXIR"}
      ...>   )
      iex> String.starts_with?(subscription.id, "__absinthe__")
      true

  Receiving the subscription data, for example on a `GenServer`:

      def handle_info(%AbsintheClient.WebSocket.Message{payload: payload}, state) do
        case payload["result"] do
          %{"errors" => errors} ->
            raise "Received result with errors, got: #{inspect(result["errors"])}"

          %{"data" => data} ->
            name = get_in(result, ~w(data subscribeToAllThings name)) do
            IO.puts("Received new thing named #{name}")

            {:noreply, state}
        end
      end
  """

  @doc """
  Attaches the `AbsintheClient` steps to a given `request`.

  Refer to `run/2` for a list of supported options.

  """
  @spec attach(Req.Request.t(), keyword) :: Req.Request.t()
  def attach(%Req.Request{} = request, options \\ []) do
    request
    |> Req.Request.register_options([:query, :variables, :ws_adapter, :ws_reply_ref, :ws_scheme])
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

  By default, the subscription operation is performed over a
  WebSocket connection. Refer to `run/2` for a list of
  supported options.

  ## Retries

  Note that due to the async nature of the WebSocket
  connection process, this function will retry the message
  if an `AbsintheClient.NotJoinedError` is returned.

  Consult the `Req.request/1` retry options for more information.

  ## Examples

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"))
      iex> AbsintheClient.subscribe!(
      ...>   client,
      ...>   "subscription($repository: Repository!){ repoCommentSubscribe(repository: $repository){ id commentary } }",
      ...>   variables: %{"repository" => "ELIXIR"}
      ...> ).ref
      nil

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"))
      iex> AbsintheClient.subscribe!(
      ...>   client,
      ...>   "subscription($repository: Repository!){ repoCommentSubscribe(repository: $repository){ id commentary } }",
      ...>   variables: %{"repository" => "ELIXIR"},
      ...>   ws_reply_ref: "my-subscription-ref"
      ...> ).ref
      "my-subscription-ref"

  """
  @spec subscribe!(Req.Request.t(), String.t(), keyword) ::
          AbsintheClient.Subscription.t()
  def subscribe!(request, subscription, options \\ [])

  def subscribe!(%Req.Request{} = request, subscription, options) do
    response =
      run!(
        request,
        subscription,
        [
          ws_adapter: true,
          ws_scheme: true,
          method: AbsintheClient.WebSocket,
          retry: &subscribe_retry/1
        ] ++ options
      )

    case response.body do
      %AbsintheClient.Subscription{} = subscription ->
        subscription

      other ->
        raise ArgumentError,
              "unexpected response from subscribe/3, " <>
                "expected AbsintheClient.Subscription.t(), " <>
                "got: #{inspect(other)}"
    end
  end

  defp subscribe_retry(%AbsintheClient.NotJoinedError{}), do: true
  defp subscribe_retry(_), do: false

  @doc """
  Runs a GraphQL operation and returns a response.

  ## Options

  Operation options:

    * `:variables` - A map of input values for the operation.

  WebSocket options:

    * `:ws_adapter` - When set to `true`, runs the operation
      via the WebSocket adapter. Defaults to `false`.

    * `:ws_reply_ref` - A unique term to track async replies.
      If set, the caller will receive latent replies from the
      caller, for instance when a subscription reconnects.
      Defaults to `nil`.

    * `:ws_scheme` - When set to `true`, overrides the URI
      scheme to be the WebSocket version (i.e `"https"` becomes
      `"wss"`). Defaults to `false`.

  All other options are forwarded to `Req.request/2`.

  ## Examples

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"))
      iex> {:ok, response} = AbsintheClient.run(client, "query{}")
      iex> response.status
      200

      iex> client = AbsintheClient.attach(Req.new(base_url: "ws://localhost:8001"))
      iex> {:error, error} = AbsintheClient.run(client, "query{}", ws_adapter: true)
      iex> error.message
      "not joined"

  """
  @spec run(Req.Request.t(), String.t(), keyword) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def run(request, operation, options \\ []) do
    # todo: remove :method once we support :get requests
    Req.request(request, [method: :post, query: operation] ++ options)
  end

  @doc """
  Runs a GraphQL operation and returns a response or raises an error.

  Refer to `run/2` for more information.
  """
  @spec run!(Req.Request.t(), String.t(), keyword) :: Req.Response.t()
  def run!(request, operation, options \\ []) do
    case run(request, operation, options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end
end
