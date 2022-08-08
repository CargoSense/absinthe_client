defmodule Absinthe.SocketUnitTest do
  use ExUnit.Case, async: false
  use Slipstream.SocketTest

  @control_topic "__absinthe__:control"

  test "connects and joins control topic" do
    socket_pid = start_supervised!({Absinthe.Socket, uri: "wss://localhost"})
    connect_and_assert_join socket_pid, @control_topic, %{}, :ok
  end

  test "push/2 sends a message to the server" do
    client = start_client!()
    msg = "msg:#{System.unique_integer()}"

    assert :ok = Absinthe.Socket.push(client, msg)
    assert_push @control_topic, "doc", %{query: ^msg}
  end

  test "push/3 sends a message to the server with extra pairs" do
    client = start_client!()
    msg = "msg:#{System.unique_integer()}"

    assert :ok = Absinthe.Socket.push(client, msg, vars: %{"foo" => "bar"})
    assert_push @control_topic, "doc", %{query: ^msg, vars: %{"foo" => "bar"}}
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

    :ok = Absinthe.Socket.clear_subscriptions(client)
    assert_push @control_topic, "unsubscribe", %{"subscriptionId" => ^sub_b}
    assert_push @control_topic, "unsubscribe", %{"subscriptionId" => ^sub_a}

    push(client, sub_b, "subscription:data", %{"result" => "should_not_be_received"})
    refute_receive %Absinthe.Subscription.Data{id: ^sub_b}, 100
  end

  test "enqueues subscriptions and sends on reconnect"

  defp start_client!(opts \\ [uri: "wss://localhost"]) do
    client_pid = start_supervised!({Absinthe.Socket, opts})
    connect_and_assert_join client_pid, @control_topic, %{}, :ok
    client_pid
  end

  defp subscribe!(client, query \\ subscription_query()) do
    # client: sends subscription to the server
    assert :ok = Absinthe.Socket.push(client, query)

    # server: receives subscription and replies with subscriptionId
    assert_push @control_topic, "doc", %{query: ^query}, ref
    reply(client, ref, {:ok, %{"subscriptionId" => sub_id = sub_id(client)}})

    sub_id
  end

  defp subscription_query, do: "subscription{ #{new_unique_id()} }"

  defp client_id(client) when is_pid(client), do: "client:#{inspect(client)}"
  defp sub_id(client), do: "#{client_id(client)}|sub:#{new_unique_id()}"
  defp result_id(client), do: "#{client_id(client)}|result:#{new_unique_id()}"
  defp new_unique_id, do: System.unique_integer([:positive, :monotonic])
end
