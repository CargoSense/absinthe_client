defmodule AbsintheClient do
  @moduledoc """
  The high-level API.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the high-level API (you're here!)

    * `AbsintheClient.Request` - the `Req` plugin with subscription adapter

    * `AbsintheClient.WebSocket` - the `Absinthe` WebSocket subscription manager

  The high-level API is how most users of AbsintheClient will
  make GraphQL requests most of the time.

  ## Examples

  Performing a `query` operation with `AbsintheClient.query!/1`:

      iex> res = AbsintheClient.query!("https://rickandmortyapi.com/graphql",
      ...>   query: "query { character(id:1){ name } }"
      ...> )
      iex> get_in(res.body, ~w(data character name))
      "Rick Sanchez"

  Same, but by explicitly building a `Req.Request` struct first:

      iex> req = AbsintheClient.new(url: "https://rickandmortyapi.com/graphql")
      iex> res = AbsintheClient.query!(req,
      ...>   query: "query { character(id:1){ name } }"
      ...> )
      iex> get_in(res.body, ~w(data character name))
      "Rick Sanchez"

  Making a query with variables:

      iex> res = AbsintheClient.query!("https://rickandmortyapi.com/graphql",
      ...>   query: "query($id: ID!) { character(id:$id){ name } }",
      ...>   variables: %{id: 2}
      ...> )
      iex> get_in(res.body, ~w(data character name))
      "Morty Smith"

  """

  @doc """
  Returns a new request struct with GraphQL steps.

  ## Examples

      iex> client = AbsintheClient.new()
      iex> client.method
      :post

  """
  @spec new(options :: keyword) :: Req.Request.t()
  def new(options \\ []) do
    {absinthe_options, req_options} =
      Keyword.split(options, [:operation_type, :query, :variables])

    AbsintheClient.Request.attach(Req.new([method: :post] ++ req_options), absinthe_options)
  end

  @doc """
  Runs a `mutation` operation.

  Refer to `request/1` for a list of supported operations.

  ## Examples

  With URL:

      iex> AbsintheClient.mutate!("https://graphqlzero.almansi.me/api",
      ...>  query: "mutation ($input: CreatePostInput!){ createPost(input: $input) { title body } }",
      ...>  variables: %{
      ...>    "input" => %{
      ...>      "title" => "My New Post",
      ...>      "body" => "This is the post body."
      ...>    }
      ...>  }
      ...>).body["data"]
      %{"createPost" => %{"title" => "My New Post", "body" => "This is the post body."}}

  With request struct:

      iex> client = AbsintheClient.new(url: "https://graphqlzero.almansi.me/api")
      iex> AbsintheClient.mutate!(client,
      ...>   query: "mutation ($input: CreatePostInput!){ createPost(input: $input) { title body } }",
      ...>   variables: %{
      ...>     "input" => %{
      ...>       "title" => "My New Post",
      ...>       "body" => "This is the post body."
      ...>     }
      ...>   }
      ...>).body["data"]
      %{"createPost" => %{"title" => "My New Post", "body" => "This is the post body."}}

  """
  @spec mutate!(String.t() | Req.Request.t()) :: Req.Response.t()
  def mutate!(url_or_request, options \\ [])

  def mutate!(%Req.Request{} = request, options) do
    request!(request, [operation_type: :mutation] ++ options)
  end

  def mutate!(url, options) do
    request!([operation_type: :mutation, url: URI.parse(url)] ++ options)
  end

  @doc """
  Runs a `subscription` operation.

  Refer to `request/1` for a list of supported options.

  ## Examples

      AbsintheClient.subscribe!(url,
        query: "subscription { itemSubscribe(id: FOO){ likes } }"
      )

  with a Request:

      client = AbsintheClient.new(url: url)

      AbsintheClient.subscribe!(client,
        query: "subscription ItemSubscription($id: ID!) { itemSubscribe(id: $id){ likes } }",
        variables: %{"id" => "some-item"}
      )

  Consult the `AbsintheClient.WebSocket` docs for more information about subscriptions.

  """
  @spec subscribe!(String.t() | Req.Request.t()) :: Req.Response.t()
  def subscribe!(url_or_request, options \\ [])

  def subscribe!(%Req.Request{} = request, options) do
    request!(request, [operation_type: :subscription] ++ options)
  end

  def subscribe!(url, options) do
    request!([operation_type: :subscription, url: URI.parse(url)] ++ options)
  end

  @doc """
  Runs a `query` operation.

  Refer to `request/1` for a list of supported options.

  ## Examples

      AbsintheClient.query!(url, query: "query { getItem(id: FOO){ id } }")

  """
  @spec query!(String.t() | Req.Request.t()) :: Req.Response.t()
  def query!(url_or_request, options \\ [])

  def query!(%Req.Request{} = request, options) do
    request!(request, [operation_type: :query] ++ options)
  end

  def query!(url, options) do
    request!([operation_type: :query, url: URI.parse(url)] ++ options)
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

  With options keyword list:

      iex> {:ok, response} =
      ...>   AbsintheClient.request(
      ...>     url: "https://rickandmortyapi.com/graphql",
      ...>     query: "query($id: ID!) { character(id:$id){ name } }",
      ...>     variables: %{id: 3}
      ...>   )
      iex> response.status
      200
      iex> response.body["errors"]
      nil
      iex> response.body["data"]
      %{"character" => %{"name" => "Summer Smith"}}

  With request struct:

      iex> client = AbsintheClient.new(
      ...>   url: "https://rickandmortyapi.com/graphql",
      ...>   query: "query($id: ID!) { character(id:$id){ name } }",
      ...>   variables: %{id: 3}
      ...> )
      iex> {:ok, response} = AbsintheClient.request(client)
      iex> response.status
      200

  With request struct and options:

      iex> client = AbsintheClient.new(url: "https://rickandmortyapi.com/graphql")
      iex> {:ok, response} =
      ...>   AbsintheClient.request(
      ...>     client,
      ...>     query: "query($id: ID!) { character(id:$id){ name } }",
      ...>     variables: %{id: 3}
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
    request(AbsintheClient.new(options), [])
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
      ...>  query: "query { character(id:1){ name } }"
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

      iex> client = AbsintheClient.new(url: "https://rickandmortyapi.com/graphql")
      iex> AbsintheClient.request!(client, query: "query { character(id:1){ name } }").status
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
