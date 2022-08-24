defmodule AbsintheClient.Request do
  @moduledoc """
  Low-level API and HTTP plugin for `Req`.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the high-level API

    * `AbsintheClient.Request` - the low-level API and HTTP plugin (you're here!)

    * AbsintheClient.Subscription - TODO

  """

  @doc """
  Attaches AbsintheClient steps to a given `request`.

  ## Examples

      iex> req = Req.new(url: "http://localhost")
      iex> req = AbsintheClient.Request.attach(req)
      iex> Keyword.has_key?(req.request_steps, :absinthe_client)
      true

  """
  @spec attach(request :: Req.Request.t(), options :: keyword) :: Request.Request.t()
  def attach(%Req.Request{} = request, options \\ []) do
    request
    |> Req.Request.register_options([:query, :variables])
    |> Req.Request.merge_options(options)
    |> Req.Request.append_request_steps(absinthe_client: &__MODULE__.request/1)
    |> Req.Request.append_response_steps(absinthe_client: &__MODULE__.response/1)
  end

  @doc false
  def request(%Req.Request{} = request) do
    case request.options[:query] do
      nil ->
        {request, %ArgumentError{message: "the :query option is required for GraphQL operations"}}

      query ->
        operation =
          if variables = request.options[:variables] do
            %{query: query, variables: variables}
          else
            %{query: query}
          end

        # todo: support :get request formatting
        %Req.Request{request | method: :post}
        |> Req.Request.merge_options(json: operation)
        |> Req.Steps.encode_body()
    end
  end

  @doc false
  def response({%Req.Request{} = request, %Req.Response{} = response}) do
    {request, response}
  end
end
