defmodule AbsintheClient do
  @moduledoc """
  High-level API for Elixir with GraphQL.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the high-level API (you're here!)

    * `AbsintheClient.Request` - the low-level API and HTTP plugin

    * AbsintheClient.Subscription - TODO

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
  Makes a GraphQL mutation and returns a response or raises an error.

  ## Examples

      AbsintheClient.mutate!(url,
        query: "mutation RepoCommentMutation($input: RepoCommentInput!){ repoComment(input: $input) { id } }",
        variables: %{"input" => %{"repository" => "ABSINTHE", "commentary" => "GraphQL!"}}
      )

  """
  @spec mutate!(String.t() | Req.Request.t()) :: AbsintheClient.Response.t()
  def mutate!(url_or_request, options \\ [])

  def mutate!(%Req.Request{} = request, options) do
    request!(request, [operation_type: :mutation] ++ options)
  end

  def mutate!(url, options) do
    request!([operation_type: :mutation, url: URI.parse(url)] ++ options)
  end

  @doc """
  Makes a GraphQL subscription and returns a response or raises an error.

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
  @spec subscribe!(String.t() | Req.Request.t()) :: AbsintheClient.Response.t()
  def subscribe!(url_or_request, options \\ [])

  def subscribe!(%Req.Request{} = request, options) do
    request!(request, [operation_type: :subscription] ++ options)
  end

  def subscribe!(url, options) do
    request!([operation_type: :subscription, url: URI.parse(url)] ++ options)
  end

  @doc """
  Makes a GraphQL query and returns a response or raises an error.

  ## Examples

      AbsintheClient.query!(url, query: "query { getItem(id: FOO){ id } }")

  """
  @spec query!(String.t() | Req.Request.t()) :: AbsintheClient.Response.t()
  def query!(url_or_request, options \\ [])

  def query!(%Req.Request{} = request, options) do
    request!(request, [operation_type: :query] ++ options)
  end

  def query!(url, options) do
    request!([operation_type: :query, url: URI.parse(url)] ++ options)
  end

  @spec request(Req.Request.t() | keyword()) ::
          {:ok, AbsintheClient.Response.t()} | {:error, Exception.t()}
  def request(request_or_options)

  def request(%Req.Request{} = request) do
    request(request, [])
  end

  def request(options) do
    request(AbsintheClient.new(options), [])
  end

  @doc """
  Makes an HTTP request.

  See `request/1` for more information.

  """
  @spec request(Req.Request.t(), options :: keyword()) ::
          {:ok, AbsintheClient.Response.t()} | {:error, Exception.t()}
  def request(request, options) when is_list(options) do
    request
    |> Req.Request.merge_options(options)
    |> AbsintheClient.Request.run()
  end

  @doc """
  Makes an HTTP request and returns a response or raises an error.

  See `request/1` for more information.

  ## Examples

      AbsintheClient.request!(url: url, query: "query { getItem(id: FOO){ id } }")

  """
  @spec request!(Req.Request.t() | keyword()) :: AbsintheClient.Response.t()
  def request!(request_or_options) do
    case request(request_or_options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Makes an HTTP request and returns a response or raises an error.

  See `request/1` for more information.

  ## Examples

      client = AbsintheClient.new(base_url: "http://localhost:4001")
      AbsintheClient.request!(client,
        url: "/graphql",
        query: "query { getItem(id: FOO){ id } }"
      )

  """
  @spec request!(Req.Request.t(), options :: keyword()) :: AbsintheClient.Response.t()
  def request!(request, options) do
    case request(request, options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end
end
