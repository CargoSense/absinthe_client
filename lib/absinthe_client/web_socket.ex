defmodule AbsintheClient.WebSocket do
  @moduledoc """
  The `Absinthe` WebSocket subscription manager.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the Absinthe client for GraphQL

    * `AbsintheClient.Steps` - the collection of `Req` steps

    * `AbsintheClient.WebSocket` - the `Absinthe` WebSocket connection (you're here!)

  The WebSocket does the following:

    * Pushes documents to the GraphQL server and forwards
      replies to the callers.

    * Manages any subscriptions received, including
      automatically re-subscribing in the event of a
      connection loss.

  Under the hood, WebSocket connections are `Slipstream`
  socket processes which are usually managed by an internal
  AbsintheClient supervisor.

  ## Examples

  Performing a `query` operation over a WebSocket:

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"), ws_adapter: true)
      iex> AbsintheClient.run!(client, ~S|{ __type(name: "Repo") { name } }|).body["data"]
      %{"__type" => %{"name" => "Repo"}}

  Performing an async `query` operation and awaiting the reply:

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"), ws_adapter: true, ws_async: true)
      iex> response = AbsintheClient.run!(client, ~S|{ __type(name: "Repo") { name } }|)
      iex> AbsintheClient.WebSocket.await_reply!(response).payload["data"]
      %{"__type" => %{"name" => "Repo"}}

  """
  alias AbsintheClient.WebSocket.{Push, Reply}

  # Connects the caller to a WebSocket process for the given `url`.
  @doc false
  @spec connect(url :: URI.t()) :: atom()
  @spec connect(owner :: pid(), url :: URI.t()) :: atom()
  def connect(owner \\ self(), %URI{} = url) do
    name = custom_socket_name(owner: owner, url: url)

    case DynamicSupervisor.start_child(
           AbsintheClient.SocketSupervisor,
           {AbsintheClient.WebSocket.AbsintheWs, {owner, name: name, uri: url}}
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

  @doc """
  Pushes a `query` over the given `socket` for execution.

  ## Handling subscription messages

  Results will be sent to the caller in the form of
  [`WebSocket.Message`](`AbsintheClient.WebSocket.Message`) structs.

  In a `GenServer` for instance, you would implement a
  [`handle_info/2`](`c:GenServer.handle_info/2`) callback:

      def handle_info(%AbsintheClient.WebSocket.Message{payload: payload}, state) do
        # code...
        {:noreply, state}
      end

  ## Examples

      iex> {:ok, ws} = AbsintheClient.WebSocket.AbsintheWs.start_link({self(), uri: "ws://localhost:8001/socket/websocket"})
      iex> {:ok, ref} = AbsintheClient.WebSocket.push(ws, ~S|{ __type(name: "Repo") { name } }|)
      iex> AbsintheClient.WebSocket.await_reply!(ref).payload["data"]
      %{"__type" => %{"name" => "Repo"}}
  """
  @spec push(
          socket :: GenServer.server(),
          query :: String.t(),
          variables :: nil | keyword() | map()
        ) :: {:ok, reference()}
  def push(socket, query, variables \\ nil)
      when is_binary(query) and (is_nil(variables) or is_list(variables) or is_map(variables)) do
    send(socket, %Push{
      event: "doc",
      params: %{query: query, variables: variables},
      pid: self(),
      ref: ref = make_ref()
    })

    {:ok, ref}
  end

  @doc """
  Awaits the server's response to a pushed document.

  ## Examples

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"), ws_adapter: true, ws_async: true)
      iex> {:ok, response} = AbsintheClient.run(client, ~S|{ __type(name: "Repo") { name } }|)
      iex> {:ok, reply} = AbsintheClient.WebSocket.await_reply(response)
      iex> reply.payload["data"]
      %{"__type" => %{"name" => "Repo"}}
  """
  @spec await_reply(Req.Response.t() | reference(), non_neg_integer()) ::
          AbsintheClient.WebSocket.Reply.t()
  def await_reply(response_or_ref, timeout \\ 5000)

  def await_reply(%Req.Response{body: ref}, timeout) when is_reference(ref) do
    await_reply(ref, timeout)
  end

  def await_reply(ref, timeout) when is_reference(ref) do
    receive do
      %Reply{ref: ^ref} = reply ->
        {:ok, reply}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  @doc """
  Awaits the server's response to a pushed document or raises an error.

  ## Examples

      iex> client = AbsintheClient.attach(Req.new(base_url: "http://localhost:8001"), ws_adapter: true, ws_async: true)
      iex> response = AbsintheClient.run!(client, ~S|{ __type(name: "Repo") { name } }|)
      iex> AbsintheClient.WebSocket.await_reply!(response).payload["data"]
      %{"__type" => %{"name" => "Repo"}}
  """
  @spec await_reply!(Req.Response.t() | reference(), non_neg_integer()) ::
          AbsintheClient.WebSocket.Reply.t()
  def await_reply!(response_or_ref, timeout \\ 5000)

  def await_reply!(%Req.Response{body: ref}, timeout) when is_reference(ref) do
    await_reply!(ref, timeout)
  end

  def await_reply!(ref, timeout) when is_reference(ref) do
    case await_reply(ref, timeout) do
      {:ok, reply} -> reply
      {:error, :timeout} -> raise RuntimeError, "timeout"
    end
  end

  # Clears all subscriptions on the given socket.
  @doc false
  @spec clear_subscriptions(socket :: GenServer.server()) :: :ok
  @spec clear_subscriptions(socket :: GenServer.server(), ref_or_nil :: nil | term()) :: :ok
  def clear_subscriptions(socket, ref \\ nil) do
    send(socket, {:clear_subscriptions, self(), ref})
    :ok
  end
end
