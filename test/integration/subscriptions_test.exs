Code.require_file("../support/http_client.exs", __DIR__)

defmodule Absinthe.Integration.SubscriptionsTest do
  use ExUnit.Case, async: true

  # server requirements:
  # - [x] AbsinthePhoenix server
  # - [x] GraphQL schema
  # - [ ] GraphQL subscription

  setup do
    # setup steps:
    # - [ ] start a client (client connects and joins control topic)

    {:ok, %{http_port: Absinthe.SocketTest.Endpoint.http_port()}}
  end

  @tag :skip
  test "pushes a subscription to the server and receives a success reply"
  # - [ ] Push a subscription to the server
  # - [ ] assert we receive a reply for this subscription

  @tag :skip
  test "pushes a invalid query to the server and receives an error reply"
  # - [ ] Push an invalid subscription to the server
  # - [ ] assert we receive a reply with an error
  # - [ ] Push a mutation to the server
  # - [ ] assert we received a reply with an error (invalid query?)
  # - [ ] Push a query to the server
  # - [ ] assert we received a reply with an error
  # - [ ] Push multiple root operations without an operationName
  # - [ ] assert we received a reply with an error

  @tag :skip
  test "forwards a subscription message to the subscribed caller"
  # - [ ] Push a subscription to the server
  # - [ ] assert we receive a reply for this subscription
  # - [ ] Trigger a subscription message on the server
  # - [ ] assert that the subscription data was received by the caller (aka self())

  @tag :skip
  test "drops replies from invalid or unknown subscriptions"
  # - [ ] Trigger a subscription message on the server
  # - [ ] assert we receive a reply for this subscription
  # - [ ] Unsubscribe from the subscription topic
  # - [ ] refute that the subscription data was received by the caller (aka self())

  @tag :skip
  test "rejoins active subscriptions on reconnect"
  # - [ ] Push a subscription to the server
  # - [ ] assert we receive a reply for this subscription
  # - [ ] Disconnect from/reconnect to the server
  # - [ ] assert we receive a reply for the re-subscription
  # - [ ] Trigger a subscription message on the server
  # - [ ] Assert that the subscription data was received by the caller (aka self())
end
