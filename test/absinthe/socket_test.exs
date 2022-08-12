defmodule Absinthe.SocketUnitTest do
  use ExUnit.Case, async: false
  use Slipstream.SocketTest

  @control_topic "__absinthe__:control"

  test "connects and joins control topic" do
    socket_pid = start_supervised!({Absinthe.Socket, uri: "wss://localhost", test_mode?: true})
    connect_and_assert_join socket_pid, @control_topic, %{}, :ok
  end

  test "push/2 sends a message to the server" do
    client = start_client!()
    msg = "msg:#{System.unique_integer()}"

    assert :ok = Absinthe.Socket.push(client, msg)
    assert_push @control_topic, "doc", %{query: ^msg}
  end

  test "push/3 sends a message to the server with variables" do
    client = start_client!()
    msg = "msg:#{System.unique_integer()}"

    assert :ok = Absinthe.Socket.push(client, msg, variables: %{"foo" => "bar"})
    assert_push @control_topic, "doc", %{query: ^msg, variables: %{"foo" => "bar"}}
  end

  test "push/3 with ref replies to the caller" do
    client = start_client!()
    msg = "msg:#{System.unique_integer()}"

    assert :ok = Absinthe.Socket.push(client, msg, ref: ref = make_ref())
    assert_push @control_topic, "doc", %{query: ^msg}, push_ref
    reply(client, push_ref, {:ok, :this_is_not_a_real_result})

    assert_receive %Absinthe.Socket.Reply{ref: ^ref, result: {:ok, :this_is_not_a_real_result}}
  end

  test "receives messages from an active subscription" do
    client = start_client!()
    sub_id = subscribe!(client)

    expected_result = %{"id" => result_id(client)}
    push(client, sub_id, "subscription:data", %{"result" => expected_result})

    assert_receive %Absinthe.Subscription.Data{id: ^sub_id, result: ^expected_result}, 100
  end

  test "clear_subscriptions/1 unsubscribes from all active subscriptions" do
    client = start_client!()
    sub_a = subscribe!(client)
    sub_b = subscribe!(client)

    :ok = Absinthe.Socket.clear_subscriptions(client, ref = make_ref())

    assert_push @control_topic, "unsubscribe", %{"subscriptionId" => ^sub_b}, sub_b_reply_ref
    assert_push @control_topic, "unsubscribe", %{"subscriptionId" => ^sub_a}, sub_a_reply_ref

    reply(client, sub_b_reply_ref, result_b = {:ok, %{"subscriptionId" => sub_b}})
    assert_receive %Absinthe.Socket.Reply{event: "unsubscribe", ref: ^ref, result: ^result_b}

    reply(client, sub_a_reply_ref, result_a = {:ok, %{"subscriptionId" => sub_a}})
    assert_receive %Absinthe.Socket.Reply{event: "unsubscribe", ref: ^ref, result: ^result_a}
  end

  test "enqueues on disconnect and re-subscribes on reconnect" do
    client = start_client!()

    # client: sends subscription to the server
    query = "msg:#{System.unique_integer()}"
    assert :ok = Absinthe.Socket.push(client, query, ref: ref = make_ref())

    # server: receives subscription and replies with subscriptionId
    assert_push @control_topic, "doc", %{query: ^query}, push_ref
    reply(client, push_ref, {:ok, %{"subscriptionId" => sub_id = sub_id(client)}})

    assert_receive %Absinthe.Socket.Reply{
      ref: ^ref,
      result: {:ok, %{"subscriptionId" => ^sub_id}}
    }

    expected_result = %{"id" => result_id(client)}
    push(client, sub_id, "subscription:data", %{"result" => expected_result})
    assert_receive %Absinthe.Subscription.Data{id: ^sub_id, result: ^expected_result}

    disconnect(client, :closed)

    connect_and_assert_join client, @control_topic, %{}, :ok

    assert_push @control_topic, "doc", %{query: ^query}, resub_ref, 1000
    reply(client, resub_ref, {:ok, %{"subscriptionId" => resub_id = sub_id(client)}})

    assert_receive %Absinthe.Socket.Reply{
      ref: ^ref,
      result: {:ok, %{"subscriptionId" => ^resub_id}}
    }

    expected_result = %{"id" => result_id(client)}
    push(client, resub_id, "subscription:data", %{"result" => expected_result})
    assert_receive %Absinthe.Subscription.Data{id: ^resub_id, result: ^expected_result}
  end

  defp start_client!(opts \\ [uri: "wss://localhost"]) do
    client_opts = Keyword.put_new(opts, :test_mode?, true)
    client_pid = start_supervised!({Absinthe.Socket, client_opts})
    connect_and_assert_join client_pid, @control_topic, %{}, :ok
    client_pid
  end

  defp subscribe!(client, query \\ subscription_query()) do
    # client: sends subscription to the server
    assert :ok = Absinthe.Socket.push(client, query, ref: ref = make_ref())

    # server: receives subscription and replies with subscriptionId
    assert_push @control_topic, "doc", %{query: ^query}, push_ref
    reply(client, push_ref, {:ok, %{"subscriptionId" => sub_id = sub_id(client)}})

    assert_receive %Absinthe.Socket.Reply{
      ref: ^ref,
      result: {:ok, %{"subscriptionId" => ^sub_id}}
    }

    sub_id
  end

  defp subscription_query, do: "subscription{ #{new_unique_id()} }"

  defp client_id(client) when is_pid(client), do: "client:#{inspect(client)}"
  defp sub_id(client), do: "#{client_id(client)}|sub:#{new_unique_id()}"
  defp result_id(client), do: "#{client_id(client)}|result:#{new_unique_id()}"
  defp new_unique_id, do: System.unique_integer([:positive, :monotonic])
end
