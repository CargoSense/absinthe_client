defmodule Absinthe.Integration.SubscriptionsTest do
  use ExUnit.Case, async: true

  # server requirements:
  # - [ ] AbsinthePhoenix server
  # - [ ] GraphQL schema w/ defined subscription(s)

  setup do
    # setup steps:
    # - [ ] start a client (client connects and joins control topic)
    :ok
  end

  test "pushes a subscription to the server and receives a success reply"
  # - [ ] Push a subscription to the server
  # - [ ] assert we receive a reply for this subscription

  test "pushes a invalid query to the server and receives an error reply"
  # - [ ] Push an invalid subscription to the server
  # - [ ] assert we receive a reply with an error
  # - [ ] Push a mutation to the server
  # - [ ] assert we received a reply with an error (invalid query?)

  test "forwards a subscription message to the subscribed caller"
  # - [ ] Push a subscription to the server
  # - [ ] assert we receive a reply for this subscription
  # - [ ] Trigger a subscription message on the server
  # - [ ] assert that the subscription data was received by the caller (aka self())

  test "drops replies from invalid or unknown subscriptions"
  # - [ ] Trigger a subscription message on the server
  # - [ ] assert we receive a reply for this subscription
  # - [ ] Unsubscribe from the subscription topic
  # - [ ] refute that the subscription data was received by the caller (aka self())

  test "rejoins active subscriptions on reconnect"
  # - [ ] Push a subscription to the server
  # - [ ] assert we receive a reply for this subscription
  # - [ ] Disconnect from/reconnect to the server
  # - [ ] assert we receive a reply for the re-subscription
  # - [ ] Trigger a subscription message on the server
  # - [ ] Assert that the subscription data was received by the caller (aka self())
end
