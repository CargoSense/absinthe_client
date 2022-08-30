defmodule AbsintheClient.Request do
  @moduledoc """
  Low-level API and HTTP plugin for `Req`.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the high-level API

    * `AbsintheClient.Request` - the low-level API and HTTP plugin (you're here!)

    * AbsintheClient.Subscription - TODO

  """

  # Attaches the AbsintheClient steps to a given `request`.
  @doc false
  @spec attach(Req.Request.t(), keyword) :: Req.Request.t()
  def attach(%Req.Request{} = request, options) do
    request
    |> Req.Request.register_options([:operation_type, :query, :variables])
    |> Req.Request.merge_options(options)
    |> Req.Request.prepend_request_steps(
      put_request_operation: &AbsintheClient.Steps.put_request_operation/1,
      run_ws_adapter: &AbsintheClient.Steps.run_ws_adapter/1
    )
    |> Req.Request.append_response_steps(
      put_response_operation: &AbsintheClient.Steps.put_response_operation/1
    )
  end

  @doc """
  Runs a request pipeline.

  Returns {:ok, response} or {:error, exception}.
  """
  def run(request) do
    case Req.request(request) do
      {:ok, %Req.Response{} = response} ->
        run_response(request, response)

      {:error, %{__exception__: true} = exception} ->
        run_error(request, exception)
    end
  end

  defp run_response(_request, resp) do
    operation = Req.Response.get_private(resp, :absinthe_client_operation)

    result(%AbsintheClient.Response{
      operation: operation,
      status: resp.status,
      headers: resp.headers,
      data: resp.body["data"],
      errors: resp.body["errors"]
    })
  end

  defp run_error(_request, exception) do
    result(exception)
  end

  defp result(%AbsintheClient.Response{} = response) do
    {:ok, response}
  end

  defp result(%{__exception__: true} = exception) do
    {:error, exception}
  end
end
