defmodule AbsintheClient.IntegrationTest do
  use ExUnit.Case

  @moduletag :integration

  doctest AbsintheClient,
    only: [
      :moduledoc,
      run: 3,
      run!: 3,
      subscribe!: 3
    ]

  doctest AbsintheClient.Steps,
    only: [
      encode_operation: 1,
      put_graphql_path: 1,
      put_ws_adapter: 1,
      put_ws_scheme: 1,
      run_absinthe_ws: 1
    ]

  doctest AbsintheClient.WebSocket,
    only: [
      :moduledoc,
      await_reply: 2,
      await_reply!: 2,
      connect: 1,
      connect!: 1,
      push: 3
    ]
end
