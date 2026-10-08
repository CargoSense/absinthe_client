defmodule AbsintheClient do
  @moduledoc ~S"""
  A `Req` plugin for GraphQL, designed for `Absinthe`.

  AbsintheClient makes it easy to perform GraphQL operations. It
  supports JSON encoded POST requests for queries and mutations and
  [Absinthe subscriptions](https://hexdocs.pm/absinthe/subscriptions.html)
  over Phoenix Channels (WebSocket).

  """
  alias AbsintheClient.{Utils, WebSocket}
  alias Req.Request

  @allowed_options ~w(graphql web_socket async connect_params max_rejections reconnect_delay reconnect)a

  @default_url "/graphql"

  @doc """
  Attaches to Req request.

  ## Options

  Request options:

    * `:graphql` - Required. The GraphQL operation to execute. It can
      be a string or a `{query, variables}` tuple, where `variables`
      is a map of input values to be sent with the document. The
      document must contain only a single GraphQL operation.

  WebSocket options:

    * `:web_socket` - Optional. The name of a WebSocket process to
      perform the operation, usually started by
      `AbsintheClient.WebSocket.connect/1`. Refer to the Subscriptions
      section for more information.

    * `:receive_timeout` - Optional. The maximum time (in milliseconds)
      to wait for the WebSocket server to reply. The default value is
      `15_000`. `Req.request/2` returns
      `{:error, %AbsintheClient.WebSocket.Timeout{}}` when the time runs
      out, and `{:error, %AbsintheClient.WebSocket.Closed{}}` when the
      socket stops before it replies.

    * `:async` - Optional. When set to `true`, AbsintheClient will
      return the Response without waiting for a reply from the
      WebSocket server. This option only applies when the `:web_socket`
      option is present. The response body will be an
      `AbsintheClient.WebSocket.Push` to pass to
      `AbsintheClient.WebSocket.await_reply/2`, or you can receive the
      `AbsintheClient.WebSocket.Reply` message with its ref yourself.
      The default value is `false`.

    * `:connect_params` - Optional. Custom params to be sent when the
      WebSocket connects, as a map or a zero-arity function that
      returns a map. Defaults to sending the bearer Authorization
      token if one is present on the request. The default value is `nil`.

    * `:max_rejections` - Optional. The number of consecutive times the
      server may reject the WebSocket connection before the socket
      stops. The default value is `5`. Refer to
      `AbsintheClient.WebSocket.connect/1` for more information.

    * `:reconnect_delay` - Optional. The time in milliseconds to wait
      before the WebSocket reconnects, or a function of the attempt
      count that returns it, the same as `:retry_delay` does for a
      request. Defaults to Slipstream's backoff after a transport
      failure and to exponential backoff with jitter after a rejected
      connection. Refer to `AbsintheClient.WebSocket.connect/1` for
      more information.

    * `:reconnect` - Optional. Whether the WebSocket reconnects after a
      disconnect. `false` stops the socket on the first disconnect, the
      same as `retry: false` does for a request. A function receives
      the disconnect reason and returns a boolean. The default value is
      `true`. Refer to `AbsintheClient.WebSocket.connect/1` for more
      information.

  If you want to set any of these options when attaching the plugin,
  pass them as the second argument.

  ## Examples

  Performing a `query` operation:

      iex> req = Req.new(base_url: "https://rickandmortyapi.com") |> AbsintheClient.attach()
      iex> Req.post!(req,
      ...>   graphql: \"""
      ...>   query {
      ...>     character(id: 1) {
      ...>       name
      ...>       location { name }
      ...>     }
      ...>   }
      ...>   \"""
      ...> ).body["data"]
      %{
        "character" => %{
          "name" => "Rick Sanchez",
          "location" => %{
            "name" => "Citadel of Ricks"
          }
        }
      }

  Performing a `query` operation with variables:

      iex> req = Req.new(base_url: "https://rickandmortyapi.com") |> AbsintheClient.attach()
      iex> Req.post!(req,
      ...>   graphql: {
      ...>     \"""
      ...>     query ($name: String!) {
      ...>       characters(filter: {name: $name}) {
      ...>         results {
      ...>           name
      ...>         }
      ...>       }
      ...>     }
      ...>     \""",
      ...>     %{name: "Cronenberg"}
      ...>   }
      ...> ).body["data"]
      %{
        "characters" => %{
          "results" => [
            %{"name" => "Cronenberg Rick"},
            %{"name" => "Cronenberg Morty"}
          ]
        }
      }

  Performing a `mutation` operation and overriding the default path:

      iex> req = Req.new(base_url: "https://graphqlzero.almansi.me") |> AbsintheClient.attach()
      iex> Req.post!(
      ...>   req,
      ...>   url: "/api",
      ...>   graphql: {
      ...>     \"""
      ...>     mutation ($input: CreatePostInput!) {
      ...>       createPost(input: $input) {
      ...>         body
      ...>         title
      ...>       }
      ...>     }
      ...>     \""",
      ...>     %{
      ...>       "input" => %{
      ...>         "title" => "My New Post",
      ...>         "body" => "This is the post body."
      ...>       }
      ...>     }
      ...>   }
      ...> ).body["data"]
      %{
        "createPost" => %{
          "body" => "This is the post body.",
          "title" => "My New Post"
        }
      }

  ## Subscriptions

  GraphQL subscriptions are long-running, stateful operations that can
  change their result over time. Clients connect to the server via the
  WebSocket protocol and the server will periodically push updates to
  the client when their subscription data changes.

  > #### Absinthe required! {: .tip}
  >
  > AbsintheClient works with servers running
  > [Absinthe subscriptions](https://hexdocs.pm/absinthe/subscriptions.html)
  > over Phoenix Channels.

  Performing a `subscription` operation:

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach()
      iex> ws = req |> AbsintheClient.WebSocket.connect!()
      iex> Req.request!(req,
      ...>   web_socket: ws,
      ...>   graphql: {
      ...>     \"""
      ...>     subscription ($repository: Repository!) {
      ...>       repoCommentSubscribe(repository: $repository) {
      ...>         id
      ...>         commentary
      ...>       }
      ...>     }
      ...>     \""",
      ...>     %{"repository" => "ELIXIR"}
      ...>   }
      ...> ).body.__struct__
      AbsintheClient.Subscription

  Performing an asynchronous `subscription` operation and awaiting the reply:

      iex> req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach()
      iex> ws = req |> AbsintheClient.WebSocket.connect!()
      iex> res = Req.request!(req,
      ...>   web_socket: ws,
      ...>   async: true,
      ...>   graphql: {
      ...>     \"""
      ...>     subscription ($repository: Repository!) {
      ...>       repoCommentSubscribe(repository: $repository) {
      ...>         id
      ...>         commentary
      ...>       }
      ...>     }
      ...>     \""",
      ...>     %{"repository" => "ELIXIR"}
      ...>   }
      ...> )
      iex> AbsintheClient.WebSocket.await_reply!(res).payload.__struct__
      AbsintheClient.Subscription

  Authorization via the request `:auth` option:

      iex> req = Req.new(base_url: "http://localhost:4002/", auth: {:bearer, "valid-token"}) |> AbsintheClient.attach()
      iex> ws = req |> AbsintheClient.WebSocket.connect!(url: "/auth-socket/websocket")
      iex> res = Req.request!(req,
      ...>   web_socket: ws,
      ...>   async: true,
      ...>   graphql: {
      ...>     \"""
      ...>     subscription ($repository: Repository!) {
      ...>       repoCommentSubscribe(repository: $repository) {
      ...>         id
      ...>         commentary
      ...>       }
      ...>     }
      ...>     \""",
      ...>     %{"repository" => "ELIXIR"}
      ...>   }
      ...> )
      iex> AbsintheClient.WebSocket.await_reply!(res).payload.__struct__
      AbsintheClient.Subscription

  Custom authorization via `:connect_params` map literal:

      iex> req =
      ...>   Req.new(base_url: "http://localhost:4002/")
      ...>   |> AbsintheClient.attach(connect_params: %{"token" => "valid-token"})
      iex> ws = req |> AbsintheClient.WebSocket.connect!(url: "/auth-socket/websocket")
      iex> res = Req.request!(req,
      ...>   web_socket: ws,
      ...>   async: true,
      ...>   graphql: {
      ...>     \"""
      ...>     subscription ($repository: Repository!) {
      ...>       repoCommentSubscribe(repository: $repository) {
      ...>         id
      ...>         commentary
      ...>       }
      ...>     }
      ...>     \""",
      ...>     %{"repository" => "ELIXIR"}
      ...>   }
      ...> )
      iex> AbsintheClient.WebSocket.await_reply!(res).payload.__struct__
      AbsintheClient.Subscription

  Refreshing credentials via a function (called before every connection attempt):

      iex> {:ok, tokens} = Agent.start_link(fn -> ["invalid-token", "valid-token"] end)
      iex> next_token = fn -> Agent.get_and_update(tokens, fn [t | rest] -> {t, rest ++ [t]} end) end
      iex> req =
      ...>   Req.new(base_url: "http://localhost:4002/", auth: fn -> {:bearer, next_token.()} end)
      ...>   |> AbsintheClient.attach()
      iex> ws = req |> AbsintheClient.WebSocket.connect!(url: "/auth-socket/websocket")
      iex> res = Req.request!(req,
      ...>   web_socket: ws,
      ...>   async: true,
      ...>   graphql: {
      ...>     \"""
      ...>     subscription ($repository: Repository!) {
      ...>       repoCommentSubscribe(repository: $repository) {
      ...>         id
      ...>         commentary
      ...>       }
      ...>     }
      ...>     \""",
      ...>     %{"repository" => "ELIXIR"}
      ...>   }
      ...> )
      iex> AbsintheClient.WebSocket.await_reply!(res).payload.__struct__
      AbsintheClient.Subscription

  Repeatedly rejected connections return an error and close the socket:

      iex> req =
      ...>   Req.new(base_url: "http://localhost:4002/", auth: {:bearer, "invalid-token"})
      ...>   |> AbsintheClient.attach(retry: false, max_rejections: 2)
      iex> ws = req |> AbsintheClient.WebSocket.connect!(url: "/auth-socket/websocket")
      iex> res = Req.request!(req,
      ...>   web_socket: ws,
      ...>   async: true,
      ...>   graphql: {
      ...>     \"""
      ...>     subscription ($repository: Repository!) {
      ...>       repoCommentSubscribe(repository: $repository) {
      ...>         id
      ...>         commentary
      ...>       }
      ...>     }
      ...>     \""",
      ...>     %{"repository" => "ELIXIR"}
      ...>   }
      ...> )
      iex> {:error, %AbsintheClient.WebSocket.Closed{reason: {:rejected, response}}} =
      ...>   AbsintheClient.WebSocket.await_reply(res)
      iex> response.status
      403
      iex> receive do
      ...>   %AbsintheClient.WebSocket.Closed{socket: ^ws, ref: nil, reason: {:rejected, response}} ->
      ...>     response.status
      ...> end
      403

  ### Subscription data

  Results will be sent to the caller as
  [`WebSocket.Message`](`AbsintheClient.WebSocket.Message`) structs.

  In a GenServer for instance, you would implement a
  [`handle_info/2`](`c:GenServer.handle_info/2`) callback:

      @impl GenServer
      def handle_info(%AbsintheClient.WebSocket.Message{event: "subscription:data", payload: payload}, state) do
        case payload["result"] do
          %{"errors" => errors} ->
            raise "Received result with errors, got: \#{inspect(result["errors"])}"

          %{"data" => data} ->
            text = get_in(result, ~w(data repoCommentSubscribe commentary))
            IO.puts("Received a new comment: \#{text}")
        end

        {:noreply, state}
      end

  """
  @spec attach(Request.t(), keyword()) :: Request.t()
  def attach(%Request{} = request, options \\ []) do
    request
    |> Request.prepend_request_steps(graphql_run: &run/1)
    |> Request.register_options(@allowed_options)
    |> Request.merge_options(options)
  end

  defp run(%Request{options: options} = request) do
    if doc = options[:graphql] do
      request
      |> put_default_url()
      |> encode_operation(doc)
      |> put_ws_adapter()
    else
      request
    end
  end

  defp encode_operation(%{method: :post} = request, query) do
    encode_json(request, query)
  end

  defp encode_operation(request, _doc) do
    request
  end

  defp encode_json(request, doc) do
    json = Utils.request_json!(doc)
    Request.merge_options(request, json: json)
  end

  defp put_default_url(request) do
    update_in(request.url.path, fn
      nil -> @default_url
      url -> url
    end)
  end

  defp put_ws_adapter(%Request{} = request) do
    case Map.fetch(request.options, :web_socket) do
      {:ok, _web_socket} ->
        # The socket holds the credentials, so the auth step must not run a
        # token function for every push.
        Request.delete_option(%Request{request | adapter: WebSocket}, :auth)

      :error ->
        request
    end
  end
end
