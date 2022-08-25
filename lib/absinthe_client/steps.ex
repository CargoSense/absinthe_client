defmodule AbsintheClient.Steps do
  # Req steps for AbsintheClient
  @moduledoc false

  @doc """
  The request step builds and encodes the GraphQL Operation.
  """
  def request(request) do
    # todo: remove once we support :get request formatting
    unless request.method == :post do
      raise ArgumentError,
            "only :post requests are currently supported, got: #{inspect(request.method)}"
    end

    if operation = AbsintheClient.Request.get_operation(request) do
      # todo: support :get request formatting
      %{request | body: Jason.encode_to_iodata!(operation)}
      |> Req.Request.put_new_header("content-type", "application/json")
    else
      {request, %ArgumentError{message: "expected a GraphQL operation on the request, got: nil"}}
    end
  end

  @doc """
  The response step combines the Operation with its result.
  """
  def response({%Req.Request{} = request, %Req.Response{} = response}) do
    {request, response}
  end
end
