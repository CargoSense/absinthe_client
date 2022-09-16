defmodule AbsintheClient do
  @moduledoc ~S"""
  A `Req` plugin for GraphQL, designed for `Absinthe`.

  AbsintheClient makes it easy to perform GraphQL operations.

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

  > #### Absinthe subscriptions required! {: .tip}
  >
  > AbsintheClient works with servers using
  > [Absinthe subscriptions](https://hexdocs.pm/absinthe/subscriptions.html).

  Performing a `subscription` operation:

      iex> req = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"))
      iex> AbsintheClient.subscribe!(req, {
      ...>   \"""
      ...>   subscription($repository: Repository!) {
      ...>     repoCommentSubscribe(repository: $repository) {
      ...>       id
      ...>       commentary
      ...>     }
      ...>   }
      ...>   \""",
      ...>   %{"repository" => "ELIXIR"}
      ...> }).body.__struct__
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
  alias AbsintheClient.WebSocket
  alias Req.Request

  @allowed_options ~w(graphql web_socket ws_adapter ws_async)a

  @default_url "/graphql"

  @doc """
  Attaches the `AbsintheClient` steps to a given `request`.

  ## Request options

    * `:graphql` - Required. The GraphQL operation to execute. It can
      be a string or a `{query, variables}` tuple, where `variables`
      is a map of input values to be sent with the document. The
      document must contain only a single GraphQL operation.

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

    Performing a `query` operation:

      iex> url = "https://rickandmortyapi.com"
      iex> doc = \"""
      ...> query {
      ...>   character(id: 1) {
      ...>     name
      ...>   }
      ...> }
      ...>\"""
      iex> req = Req.new(base_url: url) |> AbsintheClient.attach()
      iex> Req.post!(req, graphql: doc).body["data"]
      %{"character" => %{"name" => "Rick Sanchez"}}

    Performing a `query` operation with variables:

      iex> url = "https://rickandmortyapi.com"
      iex> doc = \"""
      ...> query($id: ID!) {
      ...>   character(id: $id) {
      ...>     name
      ...>   }
      ...> }
      ...>\"""
      iex> req = Req.new(base_url: url) |> AbsintheClient.attach()
      iex> Req.post!(req, graphql: {doc, %{id: 3}}).body["data"]
      %{"character" => %{"name" => "Summer Smith"}}

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
      |> put_ws_scheme()
      |> encode_operation(doc)
      |> put_ws_adapter()
    else
      request
    end
  end

  defp encode_operation(%{method: :post} = request, query) do
    encode_json(request, query)
  end

  defp encode_operation(request, doc) do
    if request.options[:ws_adapter] do
      encode_json(request, doc)
    else
      request
    end
  end

  defp encode_json(request, doc) do
    json =
      case query_vars!(doc) do
        {query, nil} -> %{query: query}
        {query, variables} -> %{query: query, variables: variables}
      end

    Request.merge_options(request, json: json)
  end

  defp put_default_url(request) do
    update_in(request.url.path, fn
      nil -> @default_url
      url -> url
    end)
  end

  @doc false
  def put_ws_scheme(request) do
    if request.options[:ws_adapter] && request.options[:base_url] do
      Request.merge_options(request,
        base_url: String.replace(request.options.base_url, "http", "ws")
      )
    else
      request
    end
  end

  defp put_ws_adapter(%Request{} = request) do
    case Map.fetch(request.options, :ws_adapter) do
      {:ok, func} when is_function(func, 1) ->
        %Request{request | adapter: func}

      {:ok, true} ->
        %Request{request | adapter: &run_absinthe_ws/1}

      {:ok, false} ->
        request

      :error ->
        request
    end
  end

  defp run_absinthe_ws(%Request{} = request) do
    socket_name =
      case Map.fetch(request.options, :web_socket) do
        {:ok, name} ->
          if request.options[:connect_options] do
            raise ArgumentError, "cannot set both :web_socket and :connect_options"
          end

          name

        :error ->
          WebSocket.connect!(request)
      end

    request = Request.put_private(request, :absinthe_client_ws, socket_name)

    {query, variables} = query_vars!(request)

    ref = WebSocket.push(socket_name, query, variables)

    if Map.get(request.options, :ws_async) do
      {request, Req.Response.new(body: ref)}
    else
      receive_timeout = Map.get(request.options, :receive_timeout, 15_000)

      case WebSocket.await_reply(ref, receive_timeout) do
        {:ok, reply} ->
          {request, reply_response(request, reply)}

        {:error, reason} ->
          {request, reason}
      end
    end
  end

  defp reply_response(%Request{} = req, %WebSocket.Reply{} = reply) do
    Req.Response.new(
      status: ws_response_status(reply.status),
      body: ws_response_body(req, reply),
      private: %{ws_push_ref: reply.push_ref}
    )
  end

  defp ws_response_status(:ok), do: 200
  defp ws_response_status(:error), do: 500

  defp ws_response_body(_req, %{payload: payload}), do: payload

  defp query_vars!(%Req.Request{options: %{graphql: doc}}), do: query_vars!(doc)
  defp query_vars!(query) when is_binary(query), do: {query, nil}
  defp query_vars!({query, nil} = doc) when is_binary(query), do: doc
  defp query_vars!({query, vars} = doc) when is_binary(query) and is_map(vars), do: doc

  defp query_vars!(other) do
    raise ArgumentError,
          "invalid GraphQL query, expected String.t() or {String.t(), map()}, got: #{inspect(other)}"
  end

  @doc """
  Performs a `subscription` operation.

  Note this operation must be performed by the WebSocket
  adapter.

  Refer to `attach/2` for a list of supported options.

  ## Examples

  Synchronous subscription:

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"))
      iex> AbsintheClient.subscribe!(
      ...>   client,
      ...>   {"subscription($repository: Repository!){ repoCommentSubscribe(repository: $repository){ id commentary } }",
      ...>   %{"repository" => "ELIXIR"}}
      ...> ).body.__struct__
      AbsintheClient.Subscription

  Asynchronous subscription:

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"))
      iex> response = AbsintheClient.subscribe!(
      ...>   client,
      ...>   {"subscription($repository: Repository!){ repoCommentSubscribe(repository: $repository){ id commentary } }",
      ...>   %{"repository" => "ELIXIR"}},
      ...>   ws_async: true
      ...> )
      iex> is_reference(response.body)
      true

  """
  @spec subscribe!(Request.t(), String.t(), keyword) :: Req.Response.t()
  def subscribe!(request, subscription, options \\ [])

  def subscribe!(%Request{} = request, subscription, options) do
    {ws_async, options} = Keyword.split(options, [:ws_async])
    request = Request.merge_options(request, ws_async)

    response =
      Req.request!(
        request,
        [url: "/socket/websocket"] ++
          options ++
          [graphql: subscription, ws_adapter: true]
      )

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
end
