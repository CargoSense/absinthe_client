defmodule AbsintheClient.WebSocket.AbsintheWs do
  @moduledoc false
  use Slipstream, restart: :temporary
  require Logger
  alias AbsintheClient.WebSocket.{Closed, Config, Push, Reply}
  alias AbsintheClient.WebSocket.Config.Source

  @control_topic "__absinthe__:control"

  # The same statuses Req's retry step treats as transient below 500.
  @transient_statuses [408, 429]

  @doc """
  Starts a Absinthe client process with the given options:

    * `:parent` - Required. The pid of the process that owns the socket.

    * `:request` - The `Req.Request` to run before each connection
      attempt, the first one included. Required unless `:config` is
      given.

    * `:config` - The `Slipstream` connection options. Required unless
      `:request` is given, in which case it is ignored and the socket
      builds the options from the request.

    * `:max_rejections` - Optional. Consecutive rejected connection
      attempts before the socket stops. Defaults to `5`.

    * `:reconnect_delay` - Optional. Milliseconds to wait before a
      reconnect attempt, or a function of the consecutive attempt count
      (starting at 0) that returns them. Defaults to Slipstream's backoff
      after a transport failure and to exponential backoff with jitter
      after a rejection.

    * `:reconnect` - Optional. `true` to reconnect after a disconnect,
      `false` to stop on the first one, or a function of the disconnect
      reason that returns a boolean. Defaults to `true`.

    * `:name` - Optional. The name of the socket process.

  ## Examples

      AbsintheClient.WebSocket.AbsintheWs.start_link(
        parent: self(),
        config: [uri: "wss://example.com/subscriptions/websocket"]
      )

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    with :ok <- validate_start(options) do
      Slipstream.start_link(__MODULE__, options, Keyword.take(options, [:name]))
    end
  end

  defp validate_start(options) do
    case {Keyword.fetch(options, :request), Keyword.fetch(options, :config)} do
      {{:ok, %Req.Request{}}, _} ->
        :ok

      {:error, {:ok, config}} ->
        with {:ok, _config} <- Slipstream.Configuration.validate(config), do: :ok

      {:error, :error} ->
        {:error, %ArgumentError{message: "expected a :request or a :config option"}}
    end
  end

  @impl Slipstream
  def init(options) do
    parent = Keyword.fetch!(options, :parent)
    parent_ref = Process.monitor(parent)

    socket =
      Slipstream.Socket.assign(Slipstream.new_socket(),
        parent: parent,
        parent_ref: parent_ref,
        request: source(Keyword.get(options, :request)),
        max_rejections: Keyword.get(options, :max_rejections, 5),
        reconnect_delay: Keyword.get(options, :reconnect_delay),
        reconnect: Keyword.get(options, :reconnect, true),
        rejections: 0,
        attempts: 0,
        connecting: false,
        parent_down: false,
        pids: %{},
        channel_connected: false,
        active_subscriptions: %{},
        inflight: %{},
        pending: []
      )

    # The config holds credentials. Slipstream keeps it in channel_config,
    # which Inspect omits, so it must not be copied into the assigns.
    case socket.assigns.request do
      nil ->
        socket = Slipstream.connect!(socket, Keyword.fetch!(options, :config))
        {:ok, assign(socket, :connecting, true)}

      %Source{} ->
        first_connect(socket)
    end
  end

  # The request is built here, in the socket, and connect/2 returns once
  # the connection process exists. Slipstream monitors this process from
  # that connection, so the parent must not be able to exit before the
  # monitor is in place. A failed build takes the reconnect path. When the
  # socket gives up at once, connect/2 returns the error and no Closed
  # message is sent.
  defp first_connect(socket) do
    case attempt_connect(socket) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        case next_attempt(socket, {:error, reason}) do
          {:retry, socket} ->
            {:ok, socket}

          {:close, socket} ->
            log_closed(socket, {:error, reason})
            {:stop, {:shutdown, {:closed, {:error, reason}}}}
        end
    end
  end

  @impl Slipstream
  def handle_connect(%{assigns: %{parent_down: true}} = socket) do
    {:stop, :shutdown, socket}
  end

  def handle_connect(socket) do
    {:ok,
     socket
     |> assign(rejections: 0, attempts: 0, connecting: false)
     |> join(@control_topic)}
  end

  @impl Slipstream
  def handle_disconnect(_reason, %{assigns: %{parent_down: true}} = socket) do
    {:stop, :shutdown, socket}
  end

  def handle_disconnect(reason, socket) do
    socket =
      socket
      |> assign(channel_connected: false, connecting: false)
      |> enqueue_active_subscriptions()

    case next_attempt(socket, reason) do
      {:retry, socket} -> {:ok, socket}
      {:close, socket} -> close(socket, reason)
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
          do: send(reply_to(push), reply(push, push_ref, result))

        new_socket = socket |> assign(assigns) |> maybe_update_subscriptions(push, result)

        {:ok, new_socket}

      {_, _} ->
        IO.warn(
          "#{inspect(__MODULE__)}.handle_reply/3 received a reply for unknown ref #{inspect(push_ref)}, got: #{inspect(result)}"
        )

        {:ok, socket}
    end
  end

  # A document ref is a reply alias, so the reply also removes the caller's
  # monitor. Unsubscribe pushes share one plain ref, so they reply to the pid.
  defp reply_to(%Push{event: "doc", ref: ref}) when is_reference(ref), do: ref
  defp reply_to(%Push{pid: pid}), do: pid

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
    {:noreply, assign(socket, :request, source(request))}
  end

  @impl Slipstream
  def handle_info(:reconnect, socket) do
    case attempt_connect(socket) do
      {:ok, socket} ->
        {:noreply, socket}

      {:error, reason} ->
        case handle_disconnect({:error, reason}, socket) do
          {:ok, socket} -> {:noreply, socket}
          {:stop, reason, socket} -> {:stop, reason, socket}
        end
    end
  end

  # The connection process monitors this one from its init. Erlang orders
  # signals per sender only, so if the socket exits before it has handled
  # that monitor signal, the connection gets a :noproc DOWN and crashes.
  # Handling any message from the connection guarantees the monitor is in
  # place, so a stop during a connection attempt waits for its outcome.
  @impl Slipstream
  def handle_info({:DOWN, ref, :process, _, _}, %{assigns: %{parent_ref: ref}} = socket) do
    if socket.assigns.connecting do
      {:noreply, assign(socket, :parent_down, true)}
    else
      {:stop, :shutdown, socket}
    end
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

  # The same switch as Req's `retry: false`: the socket stops on the first
  # disconnect instead of reconnecting.
  defp reconnect?(%{assigns: %{reconnect: fun}}, reason) when is_function(fun, 1),
    do: fun.(reason) == true

  defp reconnect?(%{assigns: %{reconnect: reconnect}}, _reason), do: reconnect == true

  # Only a reachable server that refuses the connection, or a request that
  # cannot be built, counts toward the limit. Transport errors, 5xx responses
  # and the transient 4xx statuses retry forever.
  defp rejection?({:error, {:upgrade_failure, %{status_code: status}}}),
    do: status in 400..499 and status not in @transient_statuses

  defp rejection?({:error, %Mint.TransportError{}}), do: false
  defp rejection?({:error, %{__exception__: true}}), do: true
  defp rejection?(_reason), do: false

  # Builds the config from the request and asks Slipstream to connect.
  defp attempt_connect(socket) do
    with {:ok, config} <- refresh_config(socket),
         {:ok, socket} <- Slipstream.connect(socket, config) do
      {:ok, assign(socket, :connecting, true)}
    end
  end

  # Decides whether the socket tries again and schedules the attempt if so.
  defp next_attempt(socket, reason) do
    cond do
      not reconnect?(socket, reason) ->
        {:close, socket}

      rejection?(reason) ->
        socket = update(socket, :rejections, &(&1 + 1))
        %{rejections: rejections, max_rejections: max_rejections} = socket.assigns

        if rejections >= max_rejections do
          {:close, socket}
        else
          {delay, socket} = reconnect_delay(socket, reason)
          log_rejection(reason, delay, max_rejections - rejections)
          {:retry, schedule_reconnect(socket, delay)}
        end

      true ->
        {delay, socket} = reconnect_delay(socket, reason)
        log_retry(reason, delay)
        {:retry, schedule_reconnect(socket, delay)}
    end
  end

  # Slipstream.reconnect/1 re-uses the old config, so the backoff is scheduled by hand.
  defp schedule_reconnect(socket, delay) do
    Process.send_after(self(), :reconnect, delay)
    socket
  end

  # The same knob as Req's :retry_delay. Without it a transport failure
  # follows Slipstream's backoff and a rejection follows the Req retry
  # backoff: the delay doubles from one second with jitter, and a
  # Retry-After header wins.
  defp reconnect_delay(socket, reason) do
    count = socket.assigns.attempts
    socket = assign(socket, :attempts, count + 1)

    delay =
      case socket.assigns.reconnect_delay do
        nil -> default_delay(socket, reason, count)
        delay when is_integer(delay) and delay >= 0 -> delay
        fun when is_function(fun, 1) -> custom_delay(fun, count)
      end

    {delay, socket}
  end

  defp default_delay(socket, reason, count) do
    cond do
      delay = retry_after(reason) -> delay
      rejection?(reason) -> exp_backoff_with_jitter(socket.assigns.rejections - 1)
      true -> slipstream_delay(socket, count)
    end
  end

  # Slipstream's list, as Slipstream.reconnect/1 reads it: the last value repeats.
  defp slipstream_delay(%{channel_config: %{reconnect_after_msec: times}}, count),
    do: Enum.at(times, count, List.last(times))

  # A transport failure needs a connection, so the config is always set by
  # then. This clause only keeps the socket alive if that ever changes.
  defp slipstream_delay(_socket, count), do: exp_backoff_with_jitter(count)

  defp custom_delay(fun, count) do
    case fun.(count) do
      delay when is_integer(delay) and delay >= 0 ->
        delay

      other ->
        raise ArgumentError,
              "expected :reconnect_delay function to return a non-negative integer, got: #{inspect(other)}"
    end
  end

  # Req reads Retry-After on the same two statuses.
  defp retry_after({:error, {:upgrade_failure, %{status_code: status, resp_headers: headers}}})
       when status in [429, 503] do
    Req.Response.get_retry_after(Req.Response.new(status: status, headers: headers))
  end

  defp retry_after(_reason), do: nil

  defp exp_backoff_with_jitter(n) do
    trunc(Integer.pow(2, n) * 1000 * (1 - 0.1 * :rand.uniform()))
  end

  defp log_rejection(reason, delay, left) do
    left = if left == 1, do: "1 attempt", else: "#{left} attempts"

    Logger.warning(
      "#{inspect(__MODULE__)} #{describe(reason)}, will retry in #{delay}ms, #{left} left"
    )
  end

  # Only an upgrade failure is logged. A transport error keeps the quiet retry from v0.1.
  defp log_retry({:error, {:upgrade_failure, %{status_code: status}}}, delay) do
    Logger.warning(
      "#{inspect(__MODULE__)} connection failed with status #{status}, will retry in #{delay}ms"
    )
  end

  defp log_retry(_reason, _delay), do: :ok

  defp describe({:error, {:upgrade_failure, %{status_code: status}}}),
    do: "connection rejected with status #{status}"

  defp describe({:error, %{__exception__: true} = exception}),
    do: "connection failed: (#{inspect(exception.__struct__)}) #{Exception.message(exception)}"

  defp log_closed(%{assigns: %{rejections: rejections}}, reason) do
    Logger.warning(
      "#{inspect(__MODULE__)} #{closed_because(rejections)}, got: #{inspect(reason)}"
    )
  end

  defp closed_because(0), do: "closed without reconnecting"
  defp closed_because(rejections), do: "closed after #{rejections} rejected connection attempts"

  defp source(nil), do: nil
  defp source(%Req.Request{} = request), do: Source.new(request)

  # Without a request there is nothing to refresh. Slipstream builds its
  # struct from the validated options, so the struct converts back to them.
  defp refresh_config(%{assigns: %{request: nil}, channel_config: config}),
    do: {:ok, config |> Map.from_struct() |> Map.to_list()}

  defp refresh_config(%{assigns: %{request: %Source{request: request}}}) do
    case Config.build(request) do
      {:ok, %Config{slipstream: config}} -> {:ok, config}
      {:error, exception} -> {:error, exception}
    end
  rescue
    exception ->
      # The socket reports the exception without the trace, so log it here.
      Logger.warning([
        "#{inspect(__MODULE__)} failed to build the request\n",
        Exception.format(:error, exception, __STACKTRACE__)
      ])

      {:error, exception}
  end

  defp close(socket, reason) do
    # Unregister first so a connect/2 in response to Closed starts a new socket.
    for key <- Registry.keys(AbsintheClient.SocketRegistry, self()),
        do: Registry.unregister(AbsintheClient.SocketRegistry, key)

    log_closed(socket, reason)

    {:stop, {:shutdown, {:closed, reason}}, socket}
  end

  # Every stop that is not an exit signal reaches terminate/2, so the
  # notifications live here and a crash in a callback sends Closed too. An
  # exit signal means the socket was killed or the application is stopping.
  # Registered processes are linked to their Registry partition, so a Registry
  # stop is an exit signal as well.
  @impl Slipstream
  def terminate(reason, socket) do
    notify_closed(socket, closed_reason(reason))
    disconnect(socket)
  end

  defp closed_reason({:shutdown, {:closed, reason}}), do: reason
  defp closed_reason(reason), do: reason

  defp notify_closed(socket, reason) do
    %{parent: parent, pending: pending, inflight: inflight, active_subscriptions: active} =
      socket.assigns

    # An orderly close moves the active subscriptions to pending first, but
    # a crash skips that step, so they are notified from here as well.
    for {_sub_id, %Push{pid: pid, ref: ref}} <- active,
        is_pid(pid),
        do: send(pid, %Closed{socket: self(), ref: ref, reason: reason})

    pushes =
      Enum.map(pending, &{&1, &1.pushed_counter == 0}) ++
        Enum.map(Map.values(inflight), &{&1, &1.pushed_counter == 1})

    for {%Push{pid: pid, ref: ref} = push, awaiting_reply?} <- pushes, is_pid(pid) do
      cond do
        awaiting_reply? and is_reference(ref) ->
          send(reply_to(push), reply(push, nil, {:error, reason}))

        push.event == "doc" and not awaiting_reply? ->
          send(pid, %Closed{socket: self(), ref: ref, reason: reason})

        true ->
          :ok
      end
    end

    send(parent, %Closed{socket: self(), ref: nil, reason: reason})
  end
end
