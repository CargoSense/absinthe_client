defmodule AbsintheClient do
  @moduledoc ~S"""
  The Absinthe GraphQL client.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the high-level API (you're here!)

    * `AbsintheClient.Request` - the `Req` plugin steps and subscription adapter

    * `AbsintheClient.WebSocket` - the `Absinthe` WebSocket subscription manager

  The following examples demonstrate how most users of AbsintheClient will
  make GraphQL requests most of the time.

  ## Examples

  Performing a `query` operation:

      iex> client = AbsintheClient.attach(Req.new(url: "https://rickandmortyapi.com/graphql"))
      iex> Req.post!(client, query: "query { character(id: 1) { name } }").body["data"]
      %{"character" => %{"name" => "Rick Sanchez"}}

  Performing a `query` operation with variables:

      iex> client = AbsintheClient.attach(Req.new(url: "https://rickandmortyapi.com/graphql"))
      iex> Req.post!(
      ...>   client,
      ...>   query: "query($id: ID!) { character(id: $id) { name } }",
      ...>   variables: %{id: 3}
      ...> ).body["data"]
      %{"character" => %{"name" => "Summer Smith"}}

  Performing a `mutation` operation:

      iex> client = AbsintheClient.attach(Req.new(url: "https://graphqlzero.almansi.me/api"))
      iex> Req.post!(
      ...>   client,
      ...>   query: "mutation($input: CreatePostInput!){ createPost(input: $input){ body title }}",
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

      iex> client = AbsintheClient.attach(Req.new(url: "ws://localhost:8001/socket/websocket"))
      iex> subscription =
      ...>   AbsintheClient.subscribe!(
      ...>     client,
      ...>     "subscription($repository: Repository!){ repoCommentSubscribe(repository: $repository){ id commentary } }",
      ...>     variables: %{"repository" => "ELIXIR"}
      ...>   )
      iex> String.starts_with?(subscription.id, "__absinthe__")
      true

  Receiving the subscription data, for example on a `GenServer`:

      def handle_info(%AbsintheClient.Subscription.Data{result: result}, state) do
        case result do
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

  ## Options

    * `:query` - The GraphQL document containing a single operation.

    * `:variables` - A map of input values for the operation.

  """
  @spec attach(Req.Request.t(), keyword) :: Req.Request.t()
  def attach(%Req.Request{} = request, options \\ []) do
    request
    |> Req.Request.register_options([:query, :variables])
    |> Req.Request.merge_options(options)
    |> Req.Request.prepend_request_steps(
      encode_operation: &AbsintheClient.Request.encode_operation/1
    )
  end

  @doc """
  Connects the caller to a WebSocket process for the given `request`.

  Usually you do not need to invoke this function directly as
  it is automatically invoked for subscription operations.
  However in certain cases you may want to start the socket
  process early in order to ensure that it is fully connected
  before you start pushing messages.

  Only one socket process is created per caller per request URI.

  ## Examples

      iex> req = AbsintheClient.attach(Req.new(url: AbsintheClientTest.Endpoint.subscription_url()))
      iex> socket_name = AbsintheClient.connect(req)
      iex> is_atom(socket_name)
      true

  """
  @spec connect(request :: Req.Request.t()) :: atom()
  @spec connect(owner :: pid(), request :: Req.Request.t()) :: atom()
  def connect(owner \\ self(), %Req.Request{} = request) do
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

  @doc """
  Performs a `subscription` operation over a WebSocket.

  ## WebSocket options

    * `:ws_reply_ref` - A unique term to track async replies.
      If set, the caller will receive latent replies from the
      caller, for instance when a subscription reconnects.
      Defaults to `nil`.

  ## Retries

  Note that due to the async nature of the WebSocket
  connection process, this function will retry the message
  if an `AbsintheClient.NotJoinedError` is returned.

  Consult the `Req.request/1` retry options for more information.

  ## Examples

      iex> client = AbsintheClient.attach(Req.new(url: "ws://localhost:8001/socket/websocket"))
      iex> AbsintheClient.subscribe!(
      ...>   client,
      ...>   "subscription($repository: Repository!){ repoCommentSubscribe(repository: $repository){ id commentary } }",
      ...>   variables: %{"repository" => "ELIXIR"}
      ...> ).ref
      nil

      iex> client = AbsintheClient.attach(Req.new(url: "ws://localhost:8001/socket/websocket"))
      iex> AbsintheClient.subscribe!(
      ...>   client,
      ...>   "subscription($repository: Repository!){ repoCommentSubscribe(repository: $repository){ id commentary } }",
      ...>   variables: %{"repository" => "ELIXIR"},
      ...>   ws_reply_ref: "my-subscription-ref"
      ...> ).ref
      "my-subscription-ref"

  """
  @spec subscribe!(Req.Request.t(), String.t(), keyword) :: %{
          id: String.t(),
          ref: reference()
        }
  def subscribe!(request, query, options \\ [])

  def subscribe!(%Req.Request{} = request, query, options) do
    response =
      %{request | method: AbsintheClient.WebSocket}
      |> Req.Request.register_options([:ws_reply_ref])
      |> Req.Request.prepend_request_steps(
        put_ws_adapter: &AbsintheClient.Request.put_ws_adapter/1
      )
      |> Req.request!([retry: &subscribe_retry/1, query: query] ++ options)

    %Req.Response{body: body, private: %{AbsintheClient.WebSocket => ref}} = response

    case body do
      %{"data" => %{"subscriptionId" => subscription_id}} ->
        %{id: subscription_id, ref: ref}

      other ->
        raise ArgumentError,
              "unexpected response from subscribe/3, " <>
                "expected a map with a subscriptionId key, " <>
                "got: #{inspect(other)}"
    end
  end

  defp subscribe_retry(%AbsintheClient.NotJoinedError{}), do: true
  defp subscribe_retry(_), do: false
end
