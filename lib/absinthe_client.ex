defmodule AbsintheClient do
  @moduledoc """
  The Absinthe GraphQL client.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the high-level API (you're here!)

    * `AbsintheClient.Request` - the `Req` plugin steps and subscription adapter

    * `AbsintheClient.WebSocket` - the `Absinthe` WebSocket subscription manager

  The following examples demonstrate how most users of AbsintheClient will
  make GraphQL requests most of the time.

  ## Examples

  Performing a `query` operation:

      iex> url = "https://rickandmortyapi.com/graphql"
      iex> req = Req.new(url: url) |> AbsintheClient.Request.attach()
      iex> Req.post!(req, operation: "query{ character(id:1){ name } }").body["data"]
      %{"character" => %{"name" => "Rick Sanchez"}}

  Same, but with variables:
      iex> url = "https://rickandmortyapi.com/graphql"
      iex> req = Req.new(url: url) |> AbsintheClient.Request.attach()
      iex> Req.post!(req, operation: {"query($id: ID!){ character(id:$id){ name } }", %{id: 3}}).body["data"]
      %{"character" => %{"name" => "Summer Smith"}}

  AbsintheClient is composed mostly of `Req` steps. First we
  made a new request struct and then we attached the plugin
  steps with `attach/1`. Next, we made a `:post` request with
  the query document and returned the data from the response
  body.

  """

  @doc """
  Runs a `mutation` operation.

  Refer to `request/1` for a list of supported operations.

  ## Examples

  With URL:

      iex> url = "https://graphqlzero.almansi.me/api"
      iex> doc = "mutation ($input: CreatePostInput!){ createPost(input: $input) { title body } }"
      iex> variables = %{"input" => %{"title" => "My New Post", "body" => "This is the post body."}}
      iex> AbsintheClient.mutate!(url, {doc, variables}).body["data"]
      %{"createPost" => %{"title" => "My New Post", "body" => "This is the post body."}}

  With request struct:

      iex> url = "https://graphqlzero.almansi.me/api"
      iex> doc = "mutation ($input: CreatePostInput!){ createPost(input: $input) { title body } }"
      iex> variables = %{"input" => %{"title" => "My New Post", "body" => "This is the post body."}}
      iex> client = Req.new(method: :post, url: url) |> AbsintheClient.Request.attach()
      iex> AbsintheClient.mutate!(client, {doc, variables}).body["data"]
      %{"createPost" => %{"title" => "My New Post", "body" => "This is the post body."}}

  """
  @spec mutate!(String.t() | Req.Request.t(), String.t() | {String.t(), nil | map()}, keyword) ::
          Req.Response.t()
  def mutate!(url_or_request, doc, options \\ [])

  def mutate!(%Req.Request{} = request, doc, options) do
    request!(request, [operation: {:mutation, doc}] ++ options)
  end

  def mutate!(url, doc, options) do
    request!([operation: {:mutation, doc}, url: URI.parse(url)] ++ options)
  end

  @doc """
  Runs a `subscription` operation.

  Refer to `request/1` for a list of supported options.

  ## Examples

      AbsintheClient.subscribe!(url, "subscription { itemSubscribe(id: FOO){ likes } }")

  with a Request:

      client = Req.new(url: url) |> AbsintheClient.Request.attach()

      AbsintheClient.subscribe!(client,
        {"subscription ItemSubscription($id: ID!) { itemSubscribe(id: $id){ likes } }", %{"id" => "some-item"}}
      )

  Consult the `AbsintheClient.WebSocket` docs for more information about subscriptions.

  """
  @spec subscribe!(String.t() | Req.Request.t(), String.t() | {String.t(), nil | map()}, keyword) ::
          Req.Response.t()
  def subscribe!(url_or_request, doc, options \\ [])

  def subscribe!(%Req.Request{} = request, doc, options) do
    request!(request, [operation: {:subscription, doc}] ++ options)
  end

  def subscribe!(url, doc, options) do
    request!([operation: {:subscription, doc}, url: URI.parse(url)] ++ options)
  end

  @doc """
  Runs a `query` operation.

  Refer to `request/1` for a list of supported options.

  ## Examples

      AbsintheClient.query!(url, query: "query { getItem(id: FOO){ id } }")

  """
  @spec query!(String.t() | Req.Request.t(), String.t() | {String.t(), nil | map()}) ::
          Req.Response.t()
  def query!(url_or_request, doc, options \\ [])

  def query!(%Req.Request{} = request, doc, options) do
    request!(request, [operation: {:query, doc}] ++ options)
  end

  def query!(url, doc, options) do
    request!([operation: {:query, doc}, url: URI.parse(url)] ++ options)
  end

  @doc """
  Runs a GraphQL operation.

  ## Options

  In addition to all options defined on `Req.request/1`,
  the following options are available:

    * `:operation_type` - The operation type, defaults to `:query`.

    * `:query` - The GraphQL query string. This option is required.

    * `:variables` - A map of key/value pairs to be sent with
      the query, defaults to `nil`.

  ## Examples

  With request struct:

      iex> req = Req.new(method: :post, url: "https://rickandmortyapi.com/graphql")
      iex> req = AbsintheClient.Request.attach(req,
      ...>   operation: {:query, "query($id: ID!) { character(id:$id){ name } }", %{id: 3}}
      ...> )
      iex> {:ok, response} = Req.request(req)
      iex> response.status
      200

  With request struct and options:

      iex> url = "https://rickandmortyapi.com/graphql"
      iex> req = Req.new(method: :post, url: url) |> AbsintheClient.Request.attach()
      iex> {:ok, response} =
      ...>   Req.request(
      ...>     req,
      ...>     operation: {:query, "query($id: ID!) { character(id:$id){ name } }", %{id: 3}}
      ...>   )
      iex> response.status
      200
  """
  @spec request(Req.Request.t() | keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(request_or_options)

  def request(%Req.Request{} = request) do
    request(request, [])
  end

  def request(options) do
    {absinthe_options, req_options} = Keyword.split(options, [:operation])
    req = AbsintheClient.Request.attach(Req.new([method: :post] ++ req_options), absinthe_options)
    request(req, [])
  end

  @doc """
  Runs a GraphQL operation.

  Refer to `request/1` for more information.
  """
  @spec request(Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  defdelegate request(request, options), to: Req

  @doc """
  Runs a GraphQL operation and returns a response or raises an error.

  Refer to `request/1` for more information.

  ## Examples

      iex> AbsintheClient.request!(
      ...>  url: "https://rickandmortyapi.com/graphql",
      ...>  operation: "query { character(id:1){ name } }"
      ...> ).status
      200
  """
  @spec request!(Req.Request.t() | keyword()) :: Req.Response.t()
  def request!(request_or_options) do
    case request(request_or_options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Runs a GraphQL operation and returns a response or raises an error.

  See `request/1` for more information.

  ## Examples

      iex> req = Req.new(method: :post, url: "https://rickandmortyapi.com/graphql")
      iex> req = AbsintheClient.Request.attach(req)
      iex> Req.request!(req, operation: "query { character(id:1){ name } }").status
      200
  """
  @spec request!(Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def request!(request, options) do
    case request(request, options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end
end
