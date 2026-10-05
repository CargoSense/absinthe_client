defmodule AbsintheClient.WebSocket.AbsintheWsTest do
  use ExUnit.Case, async: false
  use Slipstream.SocketTest
  import ExUnit.CaptureLog
  alias AbsintheClient.WebSocket.{AbsintheWs, Closed, Reply}

  @control_topic "__absinthe__:control"
  @rejection {:error, {:upgrade_failure, %{status_code: 403, resp_headers: [], reason: nil}}}

  test "connects and joins control topic" do
    socket_pid =
      start_supervised!(
        {AbsintheWs, parent: self(), config: [uri: "ws://localhost", test_mode?: true]}
      )

    connect_and_assert_join socket_pid, @control_topic, %{}, :ok
  end

  test "push/2 sends a message to the server" do
    client = start_client!()
    msg = "msg:#{System.unique_integer()}"

    _ref = AbsintheClient.WebSocket.push(client, {msg, nil})
    assert_push @control_topic, "doc", %{query: ^msg}
  end

  test "push/2 sends a message to the server with variables" do
    client = start_client!()
    msg = "msg:#{System.unique_integer()}"

    _ref = AbsintheClient.WebSocket.push(client, {msg, %{"foo" => "bar"}})
    assert_push @control_topic, "doc", %{query: ^msg, variables: %{"foo" => "bar"}}
  end

  test "push/2 with ref replies to the caller" do
    client = start_client!()
    msg = "msg:#{System.unique_integer()}"

    assert ref = AbsintheClient.WebSocket.push(client, msg)
    assert_push @control_topic, "doc", %{query: ^msg}, push_ref
    reply(client, push_ref, {:ok, :this_is_not_a_real_result})

    assert_receive %AbsintheClient.WebSocket.Reply{
      ref: ^ref,
      status: :ok,
      payload: :this_is_not_a_real_result
    }
  end

  test "receives messages from an active subscription" do
    client = start_client!()
    sub_id = subscribe!(client)

    expected_payload = %{"id" => result_id(client)}
    push(client, sub_id, "subscription:data", %{"result" => expected_payload})

    assert_receive %AbsintheClient.WebSocket.Message{
      event: "subscription:data",
      payload: ^expected_payload
    }
  end

  test "clear_subscriptions/1 unsubscribes from all active subscriptions" do
    client = start_client!()
    sub_a = subscribe!(client)
    sub_b = subscribe!(client)

    :ok = AbsintheClient.WebSocket.clear_subscriptions(client, ref = make_ref())

    assert_push @control_topic, "unsubscribe", %{"subscriptionId" => ^sub_b}, sub_b_reply_ref
    assert_push @control_topic, "unsubscribe", %{"subscriptionId" => ^sub_a}, sub_a_reply_ref

    reply(client, sub_b_reply_ref, {:ok, %{"subscriptionId" => sub_b}})

    assert_receive %AbsintheClient.WebSocket.Reply{
      event: "unsubscribe",
      ref: ^ref,
      payload: %AbsintheClient.Subscription{id: ^sub_b},
      status: :ok
    }

    reply(client, sub_a_reply_ref, {:ok, %{"subscriptionId" => sub_a}})

    assert_receive %AbsintheClient.WebSocket.Reply{
      event: "unsubscribe",
      ref: ^ref,
      payload: %AbsintheClient.Subscription{id: ^sub_a},
      status: :ok
    }
  end

  test "enqueues on disconnect and re-subscribes on reconnect" do
    client = start_client!()

    # client: sends subscription to the server
    query = "msg:#{System.unique_integer()}"
    assert ref = AbsintheClient.WebSocket.push(client, query)

    # server: receives subscription and replies with subscriptionId
    assert_push @control_topic, "doc", %{query: ^query}, push_ref
    reply(client, push_ref, {:ok, %{"subscriptionId" => sub_id = sub_id(client)}})

    assert_receive %AbsintheClient.WebSocket.Reply{
      ref: ^ref,
      payload: %AbsintheClient.Subscription{id: ^sub_id},
      status: :ok
    }

    expected_payload = %{"id" => result_id(client)}
    push(client, sub_id, "subscription:data", %{"result" => expected_payload})
    assert_receive %AbsintheClient.WebSocket.Message{payload: ^expected_payload}

    disconnect(client, :closed)

    connect_and_assert_join client, @control_topic, %{}, :ok

    assert_push @control_topic, "doc", %{query: ^query}, resub_ref, 1000
    reply(client, resub_ref, {:ok, %{"subscriptionId" => resub_id = sub_id(client)}})

    expected_payload = %{"id" => result_id(client)}
    push(client, resub_id, "subscription:data", %{"result" => expected_payload})
    assert_receive %AbsintheClient.WebSocket.Message{ref: ^ref, payload: ^expected_payload}
  end

  test "dropped connections do not count toward max rejections" do
    client = start_client!([uri: "wss://localhost", reconnect_after_msec: [1]], max_rejections: 1)
    ref = Process.monitor(client)

    disconnect(client, :closed)
    connect_and_assert_join client, @control_topic, %{}, :ok

    refute_received {:DOWN, ^ref, :process, ^client, _}
  end

  test "transport errors do not count toward max rejections" do
    client = start_client!([uri: "wss://localhost", reconnect_after_msec: [1]], max_rejections: 1)
    ref = Process.monitor(client)

    disconnect(client, {:error, %Mint.TransportError{reason: :econnrefused}})
    connect_and_assert_join client, @control_topic, %{}, :ok

    refute_received {:DOWN, ^ref, :process, ^client, _}
  end

  @tag :capture_log
  test "closes after max rejections and notifies the parent and subscribers" do
    client = start_client!([uri: "wss://localhost", reconnect_after_msec: [1]], max_rejections: 2)
    monitor_ref = Process.monitor(client)

    query = subscription_query()
    assert ref = AbsintheClient.WebSocket.push(client, query)
    assert_push @control_topic, "doc", %{query: ^query}, push_ref
    reply(client, push_ref, {:ok, %{"subscriptionId" => sub_id(client)}})
    assert_receive %Reply{ref: ^ref, status: :ok}

    disconnect(client, @rejection)
    _ = :sys.get_state(client)
    refute_received %Closed{}

    log =
      capture_log(fn ->
        disconnect(client, @rejection)

        assert_receive {:DOWN, ^monitor_ref, :process, ^client,
                        {:shutdown, {:closed, @rejection}}}
      end)

    assert log =~ "closed after 2 rejected connection attempts"
    assert_received %Closed{socket: ^client, ref: ^ref, reason: @rejection}
    assert_received %Closed{socket: ^client, ref: nil, reason: @rejection}
  end

  @tag :capture_log
  test "replies with an error to pushes awaiting a reply when closing" do
    client = start_client!([uri: "wss://localhost"], max_rejections: 1)

    query = subscription_query()
    assert ref = AbsintheClient.WebSocket.push(client, query)
    assert_push @control_topic, "doc", %{query: ^query}, _push_ref

    disconnect(client, @rejection)

    assert_receive %Reply{event: "doc", ref: ^ref, status: :error, payload: @rejection}
    assert_receive %Closed{socket: ^client, ref: nil, reason: @rejection}
    refute_received %Closed{ref: ^ref}
  end

  test "adopts an updated request" do
    client = start_client!()
    request = Req.new(url: "ws://localhost")

    send(client, {:update_request, request})

    assert %{assigns: %{request: ^request}} = :sys.get_state(client)
  end

  defp start_client!(config \\ [uri: "wss://localhost"], opts \\ []) do
    client_opts = Keyword.put_new(config, :test_mode?, true)
    client_pid = start_supervised!({AbsintheWs, [parent: self(), config: client_opts] ++ opts})
    connect_and_assert_join client_pid, @control_topic, %{}, :ok
    client_pid
  end

  defp subscribe!(client, query \\ subscription_query()) do
    # client: sends subscription to the server
    assert ref = AbsintheClient.WebSocket.push(client, query)

    # server: receives subscription and replies with subscriptionId
    assert_push @control_topic, "doc", %{query: ^query}, push_ref
    reply(client, push_ref, {:ok, %{"subscriptionId" => sub_id = sub_id(client)}})

    assert_receive %AbsintheClient.WebSocket.Reply{
      ref: ^ref,
      payload: %AbsintheClient.Subscription{id: ^sub_id},
      status: :ok
    }

    sub_id
  end

  defp subscription_query, do: "subscription{ #{new_unique_id()} }"

  defp client_id(client) when is_pid(client), do: "client:#{inspect(client)}"
  defp sub_id(client), do: "#{client_id(client)}|sub:#{new_unique_id()}"
  defp result_id(client), do: "#{client_id(client)}|result:#{new_unique_id()}"
  defp new_unique_id, do: System.unique_integer([:positive, :monotonic])
end
