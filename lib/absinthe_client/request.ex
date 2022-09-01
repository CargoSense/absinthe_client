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

  @doc """
  Starts a socket process for the caller and the given `request`.

  Usually you do not need to invoke this function directly,
  since it is automatically invoked by the high-level
  [`subscribe!/1`](`AbsintheClient.subscribe!/1`) function.
  However in certain cases you may want to start the socket
  process early.

  ## Examples

      iex> url = AbsintheClientTest.Endpoint.subscription_url()
      iex> client = AbsintheClient.new(url: url)
      iex> socket_name = AbsintheClient.Request.start_socket(client)
      iex> is_atom(socket_name)
      true

  """
  @spec start_socket(request :: Req.Request.t()) :: atom()
  @spec start_socket(owner :: pid(), request :: Req.Request.t()) :: atom()
  def start_socket(owner \\ self(), %Req.Request{} = request) do
    name = custom_socket_name(owner: owner, url: request.url)

    case DynamicSupervisor.start_child(
           AbsintheClient.SocketSupervisor,
           {AbsintheClient.WebSocket, {owner, name: name, uri: request.url}}
         ) do
      {:ok, _} ->
        name

      {:error, {:already_started, _}} ->
        name
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
