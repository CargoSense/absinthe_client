defmodule AbsintheClient.IntegrationTest do
  use ExUnit.Case

  doctest AbsintheClient,
    only: [
      attach: 2
    ]

  doctest AbsintheClient.WebSocket,
    only: [
      :moduledoc,
      await_reply: 2,
      await_reply!: 2,
      connect: 1,
      connect: 2,
      connect!: 1,
      connect!: 2,
      push: 2,
      run: 1
    ]
end
