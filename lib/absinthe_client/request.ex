defmodule AbsintheClient.Request do
  @moduledoc """
  Low-level API and HTTP plugin for `Req`.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the high-level API

    * `AbsintheClient.Request` - the low-level API and HTTP plugin (you're here!)

    * AbsintheClient.Subscription - TODO

  """

  @opaque t :: Req.Request.t()

  # Attaches the AbsintheClient steps to a given `request`.
  @doc false
  @spec attach(Req.Request.t(), keyword) :: AbsintheClient.Request.t()
  def attach(%Req.Request{} = request, options) do
    request
    |> Req.Request.register_options([:query, :variables])
    |> Req.Request.merge_options(options)
    |> Req.Request.append_request_steps(absinthe_client: &AbsintheClient.Steps.request/1)
    |> Req.Request.append_response_steps(absinthe_client: &AbsintheClient.Steps.response/1)
  end

  @doc """
  Returns an [`Operation`](`AbsintheClient.Operation`) for the given `request`.

  Returns `nil` if no operation is set on the request.
  """
  @spec get_operation(AbsintheClient.Request.t()) :: nil | AbsintheClient.Operation.t()
  def get_operation(request) do
    Req.Request.get_private(request, :absinthe_client_operation)
  end

  @doc """
  Puts an [`Operation`](`AbsintheClient.Operation`) struct on the given `request`.
  """
  @spec put_operation(AbsintheClient.Request.t(), AbsintheClient.Operation.t()) ::
          AbsintheClient.Request.t()
  def put_operation(request, %AbsintheClient.Operation{} = operation) do
    Req.Request.put_private(request, :absinthe_client_operation, operation)
  end

  @doc """
  Encodes the GraphQL operation data for the given `request`.

  Currently only `:post` requests are supported.
  """
  @spec encode_operation(AbsintheClient.Request.t()) :: AbsintheClient.Request.t()
  def encode_operation(%{private: %{absinthe_client_operation: op}} = request) do
    # todo: remove once we support :get request formatting
    unless request.method == :post do
      raise ArgumentError,
            "only :post requests are currently supported, got: #{inspect(request.method)}"
    end

    # todo: support :get request formatting
    %{request | body: Jason.encode_to_iodata!(op)}
    |> Req.Request.put_new_header("content-type", "application/json")
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

  defp run_response(request, resp) do
    result(%AbsintheClient.Response{
      operation: AbsintheClient.Request.get_operation(request),
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
