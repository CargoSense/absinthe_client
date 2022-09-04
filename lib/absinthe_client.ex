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

      iex> Req.post!(
      ...>   AbsintheClient.attach(Req.new(url: "https://rickandmortyapi.com/graphql")),
      ...>   operation: \"""
      ...>     query {
      ...>       character(id: 1) {
      ...>         name
      ...>       }
      ...>     }
      ...>   \"""
      ...> ).body["data"]
      %{"character" => %{"name" => "Rick Sanchez"}}

  Same, but with variables:

      iex> Req.post!(
      ...>   AbsintheClient.attach(Req.new(url: "https://rickandmortyapi.com/graphql")),
      ...>   operation: {
      ...>     \"""
      ...>     query($id: ID!) {
      ...>       character(id: $id) {
      ...>         name
      ...>       }
      ...>     }
      ...>     \""",
      ...>     %{
      ...>       id: 3
      ...>     }
      ...>   }
      ...> ).body["data"]
      %{"character" => %{"name" => "Summer Smith"}}

  Performing a `mutation` operation:

      iex> Req.post!(
      ...>   AbsintheClient.attach(Req.new(url: "https://graphqlzero.almansi.me/api")),
      ...>   operation:
      ...>     {:mutation,
      ...>      \"""
      ...>      mutation ($input: CreatePostInput!){
      ...>        createPost(input: $input){
      ...>          title
      ...>          body
      ...>        }
      ...>      }
      ...>      \""",
      ...>      %{
      ...>        "input" =>
      ...>          %{
      ...>            "title" => "My New Post",
      ...>            "body" => "This is the post body."
      ...>          }
      ...>      }
      ...>     }
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

      Req.post!(
        AbsintheClient.attach(Req.new(url: "ws://localhost:8001/socket/websocket")),
        operation:
          {:subscription,
           \"""
           subscription {
             subscribeToAllThings {
               id
               name
             }
           }
           \"""}
      )

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

  ## Request options

    * `:operation` - The GraphQL document. It may be a
      `string`, a tuple of `{string, map}`, or a tuple of
      `{atom, string, map}`.

  ## Examples

      iex> req = Req.new(method: :post, url: "ws://localhost")
      iex> req = AbsintheClient.attach(req, operation: "query{}")
      iex> req.options.operation
      "query{}"

      iex> op = {"query{}", %{"id" => 1}}
      iex> req = Req.new(method: :post, url: "ws://localhost")
      iex> req = AbsintheClient.attach(req, operation: op)
      iex> req.options.operation
      {"query{}", %{"id" => 1}}

      iex> op = {:subscription, "query{}", %{"id" => 1}}
      iex> req = Req.new(method: :post, url: "ws://localhost")
      iex> req = AbsintheClient.attach(req, operation: op)
      iex> req.options.operation
      {:subscription, "query{}", %{"id" => 1}}

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
end
