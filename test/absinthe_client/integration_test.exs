defmodule AbsintheClient.IntegrationTest do
  use ExUnit.Case

  @moduletag :integration

  doctest AbsintheClient,
    only: [
      :moduledoc,
      attach: 2,
      subscribe!: 3
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
      push: 3
    ]
end
