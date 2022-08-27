defmodule AbsintheClient.Steps do
  # Req steps for AbsintheClient
  @moduledoc false

  @doc """
  The request step builds and encodes the GraphQL Operation.
  """
  def request(request) do
    cond do
      operation = AbsintheClient.Request.get_operation(request) ->
        {operation_options, _} = Map.split(request.options, [:query, :variables])
        operation = AbsintheClient.Operation.merge_options(operation, operation_options)

        request
        |> AbsintheClient.Request.put_operation(operation)
        |> AbsintheClient.Request.encode_operation()

      _query = request.options[:query] ->
        operation = AbsintheClient.Operation.new(request, request.options)

        request
        |> AbsintheClient.Request.put_operation(operation)
        |> AbsintheClient.Request.encode_operation()

      true ->
        {request, %ArgumentError{message: "expected :query to be set, but it was not"}}
    end
  end

  @doc """
  The response step combines the Operation with its result.
  """
  def response({%Req.Request{} = request, %Req.Response{} = response}) do
    {request, response}
  end
end
