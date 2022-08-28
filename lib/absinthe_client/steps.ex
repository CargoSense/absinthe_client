defmodule AbsintheClient.Steps do
  # Req steps for AbsintheClient
  @moduledoc false

  @doc """
  The request step builds and encodes the GraphQL Operation.
  """
  def request(request) do
    # remove once we support :get request formatting
    unless request.method == :post do
      raise ArgumentError,
            "only :post requests are currently supported, got: #{inspect(request.method)}"
    end

    case build_operation(request) do
      %AbsintheClient.Operation{} = operation ->
        # todo: support :get request formatting
        request
        |> Req.Request.put_private(:absinthe_client_operation, operation)
        |> Req.Request.merge_options(json: operation)

      %{__exception__: true} = exception ->
        {request, exception}
    end
  end

  defp build_operation(request) do
    options = Map.take(request.options, [:query, :variables])

    cond do
      operation = Req.Request.get_private(request, :absinthe_client_operation) ->
        AbsintheClient.Operation.merge_options(operation, options)

      Map.has_key?(options, :query) ->
        AbsintheClient.Operation.new(options)

      true ->
        %ArgumentError{message: "expected :query to be set, but it was not"}
    end
  end

  @doc """
  The response step combines the Operation with its result.
  """
  def response({%Req.Request{} = request, %Req.Response{} = response}) do
    operation = Req.Request.get_private(request, :absinthe_client_operation)
    {request, Req.Response.put_private(response, :absinthe_client_operation, operation)}
  end
end
