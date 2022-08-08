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

    # client: sends "subscription" to the server
    msg = "msg:#{System.unique_integer()}"
    assert :ok = Absinthe.Socket.push(client, msg)

    # server: receives subscription and replies with subscriptionId
    assert_push @control_topic, "doc", %{query: ^msg}, ref
    reply(client, ref, {:ok, %{"subscriptionId" => sub_id = sub_id()}})

    # server: pushes message to subscription topic
    expected_result = %{"id" => result_id()}
    push(client, sub_id, "subscription:data", %{"result" => expected_result})

    assert_receive %Absinthe.Subscription.Data{id: ^sub_id, result: ^expected_result}, 100
  end

  test "clear_subscriptions/1 unsubscribes from all active subscriptions"

  test "enqueues subscriptions and sends on reconnect"

  defp start_client!(opts \\ [uri: "wss://localhost"]) do
    client_pid = start_supervised!({Absinthe.Socket, opts})
    connect_and_assert_join client_pid, @control_topic, %{}, :ok
    client_pid
  end

  defp sub_id, do: unique_id(:sub)
  defp result_id, do: unique_id(:result)
  defp unique_id(pre), do: "#{pre}:#{System.unique_integer([:positive, :monotonic])}"
end
