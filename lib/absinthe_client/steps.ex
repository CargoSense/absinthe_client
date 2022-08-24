defmodule AbsintheClient.Steps do
  # Req steps for AbsintheClient
  @moduledoc false

  @doc """
  The request step builds and encodes the GraphQL Operation.
  """
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

        unless request.method == :post do
          raise ArgumentError,
                "only :post requests are currently supported, got: #{inspect(request.method)}"
        end

        # todo: support :get request formatting
        request
        |> Req.Request.merge_options(json: operation)
        |> Req.Steps.encode_body()
    end
  end

  @doc """
  The response step combines the Operation with its result.
  """
  def response({%Req.Request{} = request, %Req.Response{} = response}) do
    {request, response}
  end
end
