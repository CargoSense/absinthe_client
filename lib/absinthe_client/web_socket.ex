defmodule AbsintheClient.WebSocket do
  @moduledoc """
  The `Absinthe` WebSocket subscription manager.

  AbsintheClient is composed of three main pieces:

    * `AbsintheClient` - the high-level API

    * `AbsintheClient.Request` - the `Req` plugin with subscription adapter

    * `AbsintheClient.WebSocket` - the `Absinthe` WebSocket subscription manager (you're here!)

  The WebSocket does the following:

    * Manages subscriptions received, including automatically
      replaying subscription requests in the event of a
      connection loss.

    * Forwards replies and subscription messages to the
      calling process.

  Under the hood, WebSocket connections are `Slipstream`
  socket processes which are usually managed by an internal
  AbsintheClient supervisor.

  ## Examples

      iex> {:ok, ws} = DynamicSupervisor.start_child(AbsintheClient.SocketSupervisor,
      ...>   {AbsintheClient.WebSocket, {self(), uri: "ws://localhost:8001"}}
      ...> )
      iex> Process.alive?(ws)
      true

  """
  use Slipstream, restart: :temporary
  alias AbsintheClient.WebSocket.{Push, Reply}

  @control_topic "__absinthe__:control"

  @doc """
  Pushes a `query` over the given `socket` for execution.

  ## Options

  * `:variables` - a map of query variables.

  * `:ref` - a unique term reference to track replies.

  ## Examples

      {:ok, sock} = AbsintheClient.WebSocket.start_link(uri: "wss://example.com/subscriptions/websocket")

      AbsintheClient.WebSocket.push(sock,
        "subscription ($id: ID!) {orderCreated(storeId: $id) { id } }",
        variables: %{id: "store123"}
      )

  ## Handling subscription messages

  Results will be sent to the caller in the form of
  [`Subscription.Data`](`AbsintheClient.Subscription.Data`) structs.

  In a `GenServer` for instance, you would implement `handle_info/2` callback:

      def handle_info(%AbsintheClient.Subscription.Data{id: _topic, result: payload}, state) do
        # code...
        {:noreply, state}
      end

  ## Receiving replies

  Usually only subscription data messages are sent to the
  caller. If you want to receive a push [`Reply`](`AbsintheClient.WebSocket.Reply`)
  you pass a reference to the `:ref` option:

      AbsintheClient.WebSocket.push(
        sock,
        "query GetItem($id: ID!) { item(id: $id) { name } }",
        ref: "get-item-ref"
      )

  ...and handle the reply:

      receive do
        %AbsintheClient.WebSocket.Reply{ref: "get-item-ref", result: result} ->
          # do something with result...
      after
        5_000 ->
          exit(:timeout)
      end

  """
  @spec push(socket :: GenServer.server(), query :: String.t()) :: :ok
  @spec push(socket :: GenServer.server(), query :: String.t(), opts :: Access.t()) :: :ok
  def push(socket, query, opts \\ []) when is_binary(query) do
    variables =
      case Access.fetch(opts, :variables) do
        {:ok, variables} when is_map(variables) ->
          variables

        {:ok, other} ->
          raise ArgumentError,
                "invalid :variables given to push/3, expected a map, got: #{inspect(other)}"

        :error ->
          nil
      end

    ref =
      case Access.fetch(opts, :ref) do
        {:ok, ref} ->
          ref

        :error ->
          nil
      end

    push = Push.new_doc(query, variables, self(), ref)

    send(socket, push)
    :ok
  end

  @doc """
  Pushes an operation to the GraphQL and awaits the result.

  See `push/3` for more information.
  """
  @spec push_sync(
          socket :: GenServer.server(),
          operation :: AbsintheSocket.Operation.t(),
          timeout :: non_neg_integer()
        ) ::
          {:ok, AbsintheClient.WebSocket.Reply.t()} | {:error, Exception.t()}
  def push_sync(socket, %AbsintheClient.Operation{} = operation, timeout \\ 5000) do
    push = Push.new_doc(operation.query, operation.variables, operation.owner, operation.ref)
    GenServer.call(socket, {:push_sync, push, timeout}, timeout)
  end

  @doc """
  Clears all subscriptions on the given socket.

  Subscriptions are cleared asynchronously. This function
  always returns `:ok`.

  ## Receiving replies

  Similar to `push/3`, you can have unsubscribe replies sent
  to the caller by providing a `ref` as the second argument
  to `clear_subscriptions/2`.

  ## Examples

      AbsintheClient.WebSocket.clear_subscriptions(socket)

      AbsintheClient.WebSocket.clear_subscriptions(socket, "my-unsubscribe-ref")

  """
  @spec clear_subscriptions(socket :: GenServer.server()) :: :ok
  @spec clear_subscriptions(socket :: GenServer.server(), ref_or_nil :: nil | term()) :: :ok
  def clear_subscriptions(socket, ref \\ nil) do
    send(socket, {:clear_subscriptions, self(), ref})
    :ok
  end

  @doc """
  Starts a Absinthe client process.

  ## Examples

      AbsintheClient.WebSocket.start_link(uri: "wss://example.com/subscriptions/websocket")

  """
  @spec start_link({parent :: pid, opts :: Keyword.t()}) :: GenServer.on_start()
  def start_link({parent, opts}) when is_pid(parent) and is_list(opts) do
    # todo: split init args from GenServer options.
    {name, opts} = Keyword.pop(opts, :name)
    server_opts = if name, do: [name: name], else: []

    Slipstream.start_link(__MODULE__, {parent, opts}, server_opts)
  end

  @impl Slipstream
  def init({parent, config}) do
    parent_ref = Process.monitor(parent)

    socket =
      config
      |> connect!()
      |> assign(
        parent: parent,
        parent_ref: parent_ref,
        pids: %{},
        channel_connected: false,
        active_subscriptions: %{},
        inflight: %{},
        pending: []
      )

    {:ok, socket}
  end

  @impl Slipstream
  def handle_connect(socket) do
    {:ok, join(socket, @control_topic)}
  end

  @impl Slipstream
  def handle_disconnect(_reason, socket) do
    case reconnect(socket) do
      {:ok, socket} ->
        {:ok,
         socket
         |> assign(:channel_connected, false)
         |> enqueue_active_subscriptions()}

      {:error, reason} ->
        {:stop, reason, socket}
    end
  end

  @impl Slipstream
  def handle_join(@control_topic, _join_response, socket) do
    {:ok,
     socket
     |> assign(:channel_connected, true)
     |> push_messages()}
  end

  @impl Slipstream
  def handle_message(topic, "subscription:data", %{"result" => result}, socket) do
    case Map.fetch(socket.assigns.active_subscriptions, topic) do
      {:ok, %{pid: pid}} ->
        message = %AbsintheClient.Subscription.Data{id: topic, result: result}
        send(pid, message)

      _ ->
        IO.warn(
          "#{inspect(__MODULE__)}.handle_message/4 received data for unmatched subscription topic, got: #{topic}"
        )
    end

    {:ok, socket}
  end

  @impl Slipstream
  def handle_reply(push_ref, result, socket) do
    case pop_in(socket.assigns, [:inflight, push_ref]) do
      {%Push{pid: pid} = push, assigns} when is_pid(pid) ->
        if push.ref, do: send(pid, %Reply{event: push.event, ref: push.ref, result: result})

        new_socket = socket |> assign(assigns) |> maybe_update_subscriptions(push, result)

        {:ok, new_socket}

      {_, _} ->
        IO.warn(
          "#{inspect(__MODULE__)}.handle_reply/3 received a reply for unknown ref #{inspect(push_ref)}, got: #{inspect(result)}"
        )

        {:ok, socket}
    end
  end

  defp maybe_update_subscriptions(socket, %{event: "unsubscribe"}, _result) do
    socket
  end

  defp maybe_update_subscriptions(
         socket,
         %{event: "doc", pid: pid} = push,
         {:ok, %{"subscriptionId" => sub_id}}
       ) do
    active_subscriptions = Map.put(socket.assigns.active_subscriptions, sub_id, push)
    pids = Map.update(socket.assigns.pids, pid, [sub_id], &[sub_id | &1])

    assign(socket,
      active_subscriptions: active_subscriptions,
      pids: pids
    )
  end

  defp maybe_update_subscriptions(socket, _, _), do: socket

  @impl Slipstream
  def handle_call({:push_sync, %Push{pid: pid, event: event} = push, timeout}, from, socket)
      when is_pid(pid) and event == "doc" do
    send_push_sync_attempt(push, from, 5, Kernel.trunc(timeout / 5))
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_info({:push_sync_attempt, %Push{}, _from, tries, _reply_timeout}, socket)
      when tries < 1 do
    {:stop, {:shutdown, :not_joined}, socket}
  end

  def handle_info({:push_sync_attempt, %Push{} = push, from, tries, reply_timeout}, socket) do
    case push_message(socket, push) do
      {:ok, ref} ->
        result = Slipstream.await_reply(ref, reply_timeout)
        GenServer.reply(from, result)

        {:noreply, maybe_update_subscriptions(socket, push, result)}

      {:error, :not_joined} ->
        send_push_sync_attempt(push, from, tries - 1, reply_timeout)

        {:noreply, socket}
    end
  end

  @impl Slipstream
  def handle_info(%Push{pid: pid, event: event} = push, socket)
      when is_pid(pid) and event == "doc" do
    {:noreply, socket |> update(:pending, &[push | &1]) |> push_messages()}
  end

  @impl Slipstream
  def handle_info({:clear_subscriptions, pid, ref_or_nil}, socket) do
    {sub_ids, pids} = Map.pop(socket.assigns.pids, pid)

    sub_ids = sub_ids || []

    unsubscribes =
      Enum.map(sub_ids, fn sub_id ->
        Push.new("unsubscribe", %{"subscriptionId" => sub_id}, pid, ref_or_nil)
      end)

    socket =
      socket
      |> push_messages(unsubscribes)
      |> assign(:pids, pids)
      |> update(:active_subscriptions, &Map.drop(&1, sub_ids))

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_info({:DOWN, ref, :process, _, _}, %{assigns: %{parent_ref: ref}} = socket) do
    {:stop, :shutdown, socket}
  end

  @impl Slipstream
  def handle_info(message, socket) do
    IO.warn(
      "#{inspect(__MODULE__)}.handle_info/2 received an unexpected message, got: #{inspect(message)}"
    )

    {:noreply, socket}
  end

  defp push_messages(%{assigns: %{channel_connected: true}} = socket) do
    %{pending: pending_pushes} = socket.assigns

    socket
    |> assign(:pending, [])
    |> push_messages(pending_pushes)
  end

  defp push_messages(socket) do
    socket
  end

  defp push_messages(socket, []), do: socket

  defp push_messages(socket, [%Push{} | _] = messages) do
    update(socket, :inflight, fn inflight ->
      Enum.reduce(messages, inflight, fn op, acc ->
        {:ok, push_ref} = push_message(socket, op)
        Map.put(acc, push_ref, op)
      end)
    end)
  end

  defp push_message(socket, op) do
    push(socket, @control_topic, op.event, op.params)
  end

  defp send_push_sync_attempt(push, from, tries, reply_timeout) do
    Process.send_after(self(), {:push_sync_attempt, push, from, tries, reply_timeout}, 150)
  end

  defp enqueue_active_subscriptions(socket) do
    %{active_subscriptions: subs, pending: pending} = socket.assigns

    new_pending =
      Enum.reduce(subs, pending, fn {_, %Push{} = push}, acc ->
        [push | acc]
      end)

    assign(socket, active_subscriptions: %{}, pending: new_pending)
  end
end
