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

      iex> req = AbsintheClient.attach(Req.new(url: "https://rickandmortyapi.com/graphql"))
      iex> Req.post!(req, operation: "query{ character(id:1){ name } }").body["data"]
      %{"character" => %{"name" => "Rick Sanchez"}}

  Same, but with variables:
      iex> url = "https://rickandmortyapi.com/graphql"
      iex> req = AbsintheClient.attach(Req.new(url: url))
      iex> query = "query($id: ID!){ character(id:$id){ name } }"
      iex> Req.post!(req, operation: {query, %{id: 3}}).body["data"]
      %{"character" => %{"name" => "Summer Smith"}}

  Performing a `mutation` operation:

      iex> url = "https://graphqlzero.almansi.me/api"
      iex> req = AbsintheClient.attach(Req.new(method: :post, url: url))
      iex> query = "mutation ($input: CreatePostInput!){ createPost(input: $input) { title body } }"
      iex> variables = %{"input" => %{"title" => "My New Post", "body" => "This is the post body."}}
      iex> Req.post!(req, operation: {:mutation, query, variables}).body["data"]
      %{"createPost" => %{"title" => "My New Post", "body" => "This is the post body."}}

  ## Subscriptions

  TODO

      doc = {"subscription ItemSubscription($id: ID!) { itemSubscribe(id: $id){ likes } }", %{"id" => "some-item"}}

      req = Req.new(url: url) |> AbsintheClient.attach()

      Req.post!(req, operation: doc)
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
end
