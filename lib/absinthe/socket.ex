defmodule Absinthe.Socket do
  @moduledoc """
  WebSocket client for [Absinthe](https://hexdocs.pm/absinthe).
  """
  use Slipstream, restart: :temporary

  @control_topic "__absinthe__:control"

  @doc """
  Pushes a `query` over the given `socket` for execution.

  ## Examples

      {:ok, sock} = Absinthe.Socket.start_link(uri: "wss://example.com/subscriptions/websocket")

      Absinthe.Socket.push(sock,
        "subscription ($id: ID!) {orderCreated(storeId: $id) { id } }",
        variables: %{id: "store123"}
      )

  ### Handling subscription messages

  Results will be sent to the caller in the form of
  [`Subscription.Data`](`Absinthe.Subscription.Data`) structs.

  In a `GenServer` for instance, you would implement `handle_info/2` callback:

      def handle_info(%Absinthe.Subscription.Data{id: _topic, result: payload}, state) do
        # code...
        {:noreply, state}
      end

  """
  @spec push(socket :: GenServer.server(), query :: term()) :: :ok
  @spec push(socket :: GenServer.server(), query :: term(), opts :: Enumerable.t()) :: :ok
  def push(socket, query, opts \\ []) do
    payload =
      opts
      |> Map.new()
      |> Map.put(:query, query)

    send(socket, {:run, payload, self()})
    :ok
  end

  @doc """
  Clears all subscriptions on the given socket.

  Subscriptions are cleared asynchronously. This function
  always returns `:ok`.

  ## Examples

      Absinthe.Socket.clear_subscriptions(socket)

  """
  @spec clear_subscriptions(socket :: GenServer.server()) :: :ok
  def clear_subscriptions(socket) do
    send(socket, {:clear_subscriptions, self()})
    :ok
  end

  @doc """
  Starts a Absinthe client process.

  ## Examples

      Absinthe.Socket.start_link(uri: "wss://example.com/subscriptions/websocket")

  """
  @spec start_link(opts :: Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    # todo: split init args from GenServer options.
    Slipstream.start_link(__MODULE__, opts)
  end

  @impl Slipstream
  def init(config) do
    socket =
      config
      |> connect!()
      |> assign(
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
        message = %Absinthe.Subscription.Data{id: topic, result: result}
        send(pid, message)

      _ ->
        IO.warn(
          "#{inspect(__MODULE__)}.handle_message/4 received data for unmatched subscription topic, got: #{topic}"
        )
    end

    {:ok, socket}
  end

  @impl Slipstream
  def handle_reply(ref, {:ok, %{"subscriptionId" => sub_id}}, socket) do
    new_assigns =
      case pop_in(socket.assigns, [:inflight, ref]) do
        {%{pid: pid, payload: payload}, assigns} ->
          active_subscriptions =
            Map.put(assigns.active_subscriptions, sub_id, %{pid: pid, payload: payload})

          pids = Map.update(assigns.pids, pid, [sub_id], &[sub_id | &1])

          %{
            assigns
            | active_subscriptions: active_subscriptions,
              pids: pids
          }

        {_, assigns} ->
          assigns
      end

    {:ok, assign(socket, new_assigns)}
  end

  @impl Slipstream
  def handle_reply(ref, message, socket) do
    IO.warn(
      "#{inspect(__MODULE__)}.handle_reply/3 received an unexpected message for ref #{inspect(ref)}, got: #{inspect(message)}"
    )

    {:ok, socket}
  end

  @impl Slipstream
  def handle_info({:run, payload, pid}, socket) do
    socket =
      socket
      |> update(:pending, &[%{pid: pid, payload: payload} | &1])
      |> push_messages()

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_info({:clear_subscriptions, pid}, socket) do
    {sub_ids, pids} = Map.pop(socket.assigns.pids, pid)

    sub_ids = sub_ids || []

    Enum.each(sub_ids, fn sub_id ->
      push(socket, @control_topic, "unsubscribe", %{"subscriptionId" => sub_id})
    end)

    socket =
      socket
      |> assign(:pids, pids)
      |> update(:active_subscriptions, &Map.drop(&1, sub_ids))

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_info(message, socket) do
    IO.warn(
      "#{inspect(__MODULE__)}.handle_info/2 received an unexpected message, got: #{inspect(message)}"
    )

    {:noreply, socket}
  end

  defp push_messages(%{assigns: %{channel_connected: true}} = socket) do
    %{inflight: inflight_msgs, pending: pending_msgs} = socket.assigns

    # todo: wrap in telemetry span?
    new_inflight_msgs =
      Enum.reduce(
        pending_msgs,
        inflight_msgs,
        fn %{payload: payload} = op, acc ->
          {:ok, ref} = push(socket, @control_topic, "doc", payload)
          Map.put(acc, ref, op)
        end
      )

    assign(socket, inflight: new_inflight_msgs, pending: [])
  end

  defp push_messages(socket) do
    socket
  end
end
