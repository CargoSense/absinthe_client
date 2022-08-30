defmodule AbsintheClient.Steps do
  # Req steps for AbsintheClient
  @moduledoc false

  @client_operation_key :absinthe_client_operation

  @doc """
  Build and persists the GraphQL [`Operation`](`AbsintheClient.Operation`).

  ## Request options

    - `:operation_type` - One of `:query`, `:mutation`, or `:subscription`.

    - `:query` - The GraphQL query string.

    - `:variables` - A map of key-value pairs to be sent with the query.

  ## Examples

      iex> AbsintheClient.query!(query: "query SomeItem{ getItem{ id } }").data
      %{"getItem" => %{"id" => "abc123"}}

      iex> AbsintheClient.query!(
      ...> query: "query SomeItem($id: ID!){ getItem(id: $id){ id name } }",
      ...> variables: %{id => "my-item"}).data
      %{"getItem" => %{"id" => "my-item", "name" => "My Item"}}

  """
  def put_request_operation(%Req.Request{} = request) do
    # remove once we support :get request formatting
    unless request.method == :post do
      raise ArgumentError,
            "only :post requests are currently supported, got: #{inspect(request.method)}"
    end

    case build_operation(request) do
      %AbsintheClient.Operation{} = operation ->
        request = put_operation(request, operation)

        # todo: support :get request formatting
        %{request | body: Jason.encode_to_iodata!(operation)}
        |> Req.Request.put_new_header("content-type", "application/json")

      %{__exception__: true} = exception ->
        {request, exception}
    end
  end

  @doc """
  Copies the operation from the request to the response.
  """
  def put_response_operation({%Req.Request{} = request, %Req.Response{} = response}) do
    operation = fetch_operation!(request, :put_response_operation)
    {request, put_operation(response, operation)}
  end

  defp build_operation(request) do
    options = Map.take(request.options, [:operation_type, :query, :variables])

    cond do
      operation = get_operation(request) ->
        AbsintheClient.Operation.merge_options(operation, options)

      Map.has_key?(options, :query) ->
        AbsintheClient.Operation.new(options)

      true ->
        %ArgumentError{message: "expected :query to be set, but it was not"}
    end
  end

  defp fetch_operation!(%Req.Request{} = request, step) do
    case get_operation(request) do
      %AbsintheClient.Operation{} = operation ->
        operation

      nil ->
        raise ArgumentError, "no GraphQL operation found on request step #{inspect(step)}"

      other ->
        raise ArgumentError,
              "expected an %AbsintheClient.Operation{} on request step #{inspect(step)}, got: #{inspect(other)}"
    end
  end

  defp get_operation(request) do
    Req.Request.get_private(request, @client_operation_key)
  end

  defp put_operation(%mod{} = request_or_response, %AbsintheClient.Operation{} = operation)
       when mod in [Req.Request, Req.Response] do
    mod.put_private(request_or_response, @client_operation_key, operation)
  end

  @doc """
  Overrides the HTTP adapter for subscription requests.
  """
  def run_ws_adapter(%Req.Request{} = request) do
    case fetch_operation!(request, :put_ws_adapter) do
      %AbsintheClient.Operation{operation_type: :subscription} ->
        %Req.Request{request | adapter: &run_absinthe_ws_adapter/1}

      _ ->
        request
    end
  end

  defp run_absinthe_ws_adapter(%Req.Request{} = request) do
    operation = fetch_operation!(request, :run_absinthe_ws_adapter)
    name = custom_socket_name(owner: operation.owner, url: request.url)

    socket_name =
      case DynamicSupervisor.start_child(
             AbsintheClient.SocketSupervisor,
             {Absinthe.Socket, name: name, parent: operation.owner, uri: request.url}
           ) do
        {:ok, _} ->
          name

        {:error, {:already_started, _}} ->
          name
      end

    operation_ref = make_ref()
    operation = %AbsintheClient.Operation{operation | ref: operation_ref}
    new_request = put_operation(request, operation)

    # - [ ] todo (bonus): add push_sync function to Absinthe.Socket
    :ok =
      Absinthe.Socket.push(socket_name, operation.query,
        variables: operation.variables,
        ref: operation.ref
      )

    receive do
      %Absinthe.Socket.Reply{ref: ^operation_ref, result: result} ->
        case result do
          {:error, %{__exception__: true} = exception, _stack} ->
            {new_request, exception}

          {_, payload} ->
            {new_request, Req.Response.new(body: payload)}
        end
    after
      5_000 ->
        {request, %RuntimeError{message: "timeout"}}
    end
  end

  defp custom_socket_name(options) do
    name =
      options
      |> :erlang.term_to_binary()
      |> :erlang.md5()
      |> Base.url_encode64(padding: false)

    Module.concat(AbsintheClient.SocketSupervisor, "Socket_#{name}")
  end
end
