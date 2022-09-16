defmodule AbsintheClient.WebSocket.AbsintheWs do
  @moduledoc false
  use Slipstream, restart: :temporary
  alias AbsintheClient.WebSocket.{Push, Reply}

  @control_topic "__absinthe__:control"

  @doc """
  Starts a Absinthe client process.

  ## Examples

      AbsintheClient.WebSocket.AbsintheWs.start_link({self(), url: "wss://example.com/subscriptions/websocket"})

  """
  @spec start_link({pid(), config :: Keyword.t()}) :: GenServer.on_start()
  @spec start_link({pid(), config :: Keyword.t(), genserver_options :: GenServer.options()}) ::
          GenServer.on_start()
  def start_link(config) when is_list(config), do: start_link({self(), config, []})
  def start_link({parent, config}) when is_pid(parent), do: start_link({parent, config, []})

  def start_link({parent, config, options}) do
    with {:ok, _config} <- Slipstream.Configuration.validate(config) do
      Slipstream.start_link(__MODULE__, {parent, config}, options)
    end
  end

  @impl Slipstream
  def init({parent, config}) do
    parent_ref = Process.monitor(parent)

    socket =
      config
      |> Slipstream.connect!()
      |> Slipstream.Socket.assign(
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
  def handle_message(topic, "subscription:data" = event, %{"result" => payload}, socket) do
    case Map.fetch(socket.assigns.active_subscriptions, topic) do
      {:ok, %Push{ref: ref, pid: pid}} ->
        message = %AbsintheClient.WebSocket.Message{
          topic: topic,
          event: event,
          payload: payload,
          ref: ref
        }

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
        if is_reference(push.ref) and push.pushed_counter == 1,
          do: send(pid, reply(push, push_ref, result))

        new_socket = socket |> assign(assigns) |> maybe_update_subscriptions(push, result)

        {:ok, new_socket}

      {_, _} ->
        IO.warn(
          "#{inspect(__MODULE__)}.handle_reply/3 received a reply for unknown ref #{inspect(push_ref)}, got: #{inspect(result)}"
        )

        {:ok, socket}
    end
  end

  defp reply(%Push{} = push, push_ref, result),
    do: reply(%Reply{event: push.event, ref: push.ref, push_ref: push_ref}, result)

  defp reply(reply, :ok), do: %Reply{reply | status: :ok, payload: nil}
  defp reply(reply, :error), do: %Reply{reply | status: :error, payload: nil}

  defp reply(reply, {:ok, payload}),
    do: %Reply{reply | status: :ok, payload: payload(reply, payload)}

  defp reply(reply, {:error, payload}),
    do: %Reply{reply | status: :error, payload: error_payload(reply, payload)}

  defp payload(reply, %{"subscriptionId" => subscription_id}) do
    %AbsintheClient.Subscription{
      socket: self(),
      ref: reply.ref,
      id: subscription_id
    }
  end

  defp payload(_reply, payload), do: payload

  defp error_payload(_, payload), do: payload

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
        Push.new(
          event: "unsubscribe",
          params: %{"subscriptionId" => sub_id},
          pid: pid,
          ref: ref_or_nil
        )
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
        Map.put(acc, push_ref, %{op | pushed_counter: op.pushed_counter + 1})
      end)
    end)
  end

  defp push_message(socket, op) do
    Slipstream.push(socket, @control_topic, op.event, op.params)
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
