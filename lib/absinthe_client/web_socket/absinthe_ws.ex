defmodule AbsintheClient.WebSocket.AbsintheWs do
  @moduledoc false
  use Slipstream, restart: :temporary
  require Logger
  alias AbsintheClient.WebSocket.{Closed, Config, Push, Reply}

  @control_topic "__absinthe__:control"

  @doc """
  Starts a Absinthe client process with the given options:

    * `:parent` - Required. The pid of the process that owns the socket.

    * `:config` - Required. The `Slipstream` connection options.

    * `:request` - Optional. The `Req.Request` to re-run before each
      connection attempt. Defaults to `nil`, which re-uses `:config`.

    * `:max_rejections` - Optional. Consecutive rejected connection
      attempts before the socket stops. Defaults to `5`.

    * `:name` - Optional. The name of the socket process.

  ## Examples

      AbsintheClient.WebSocket.AbsintheWs.start_link(
        parent: self(),
        config: [uri: "wss://example.com/subscriptions/websocket"]
      )

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    config = Keyword.fetch!(options, :config)

    with {:ok, _config} <- Slipstream.Configuration.validate(config) do
      Slipstream.start_link(__MODULE__, options, Keyword.take(options, [:name]))
    end
  end

  @impl Slipstream
  def init(options) do
    parent = Keyword.fetch!(options, :parent)
    config = Keyword.fetch!(options, :config)
    parent_ref = Process.monitor(parent)

    socket =
      config
      |> Slipstream.connect!()
      |> Slipstream.Socket.assign(
        parent: parent,
        parent_ref: parent_ref,
        config: config,
        request: Keyword.get(options, :request),
        max_rejections: Keyword.get(options, :max_rejections, 5),
        rejections: 0,
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
    {:ok, socket |> assign(:rejections, 0) |> join(@control_topic)}
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    socket =
      socket
      |> assign(:channel_connected, false)
      |> enqueue_active_subscriptions()
      |> count_rejection(reason)

    if socket.assigns.rejections >= socket.assigns.max_rejections do
      close(socket, reason)
    else
      schedule_reconnect(socket)
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

  defp reply(%Reply{} = reply, :ok), do: %{reply | status: :ok, payload: nil}
  defp reply(%Reply{} = reply, :error), do: %{reply | status: :error, payload: nil}

  defp reply(%Reply{} = reply, {:ok, payload}),
    do: %{reply | status: :ok, payload: payload(reply, payload)}

  defp reply(%Reply{} = reply, {:error, payload}),
    do: %{reply | status: :error, payload: error_payload(reply, payload)}

  defp payload(%Reply{} = reply, %{"subscriptionId" => subscription_id}) do
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
  def handle_info({:update_request, %Req.Request{} = request}, socket) do
    {:noreply, assign(socket, :request, request)}
  end

  @impl Slipstream
  def handle_info(:reconnect, socket) do
    with {:ok, config} <- refresh_config(socket),
         {:ok, socket} <- Slipstream.connect(socket, config) do
      {:noreply, socket}
    else
      {:error, reason} ->
        case handle_disconnect({:error, reason}, socket) do
          {:ok, socket} -> {:noreply, socket}
          {:stop, reason, socket} -> {:stop, reason, socket}
        end
    end
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

  # Only a reachable server that refuses the connection counts toward the limit.
  defp count_rejection(socket, {:error, {:upgrade_failure, %{status_code: status}}})
       when status in 400..499 do
    update(socket, :rejections, &(&1 + 1))
  end

  defp count_rejection(socket, {:error, %Mint.TransportError{}}), do: socket

  defp count_rejection(socket, {:error, %{__exception__: true}}) do
    update(socket, :rejections, &(&1 + 1))
  end

  defp count_rejection(socket, _reason), do: socket

  # Slipstream.reconnect/1 re-uses the old config, so the backoff is scheduled by hand.
  defp schedule_reconnect(socket) do
    {time, socket} = Slipstream.Socket.next_reconnect_time(socket)
    Process.send_after(self(), :reconnect, time)
    {:ok, socket}
  end

  defp refresh_config(%{assigns: %{request: nil, config: config}}), do: {:ok, config}

  defp refresh_config(%{assigns: %{request: request}}) do
    case Config.build(request) do
      {:ok, %Config{slipstream: config}} -> {:ok, config}
      {:error, exception} -> {:error, exception}
    end
  rescue
    exception -> {:error, exception}
  end

  defp close(socket, reason) do
    %{parent: parent, pending: pending, inflight: inflight, rejections: rejections} =
      socket.assigns

    Logger.warning(
      "#{inspect(__MODULE__)} closed after #{rejections} rejected connection attempts, got: #{inspect(reason)}"
    )

    pushes =
      Enum.map(pending, &{&1, &1.pushed_counter == 0}) ++
        Enum.map(Map.values(inflight), &{&1, &1.pushed_counter == 1})

    for {%Push{pid: pid, ref: ref} = push, awaiting_reply?} <- pushes, is_pid(pid) do
      cond do
        awaiting_reply? and is_reference(ref) ->
          send(pid, reply(push, nil, {:error, reason}))

        push.event == "doc" and not awaiting_reply? ->
          send(pid, %Closed{socket: self(), ref: ref, reason: reason})

        true ->
          :ok
      end
    end

    send(parent, %Closed{socket: self(), ref: nil, reason: reason})

    {:stop, {:shutdown, {:closed, reason}}, socket}
  end
end
