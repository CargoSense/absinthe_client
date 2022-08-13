defmodule Absinthe.Socket.Integration.SocketTest do
  use ExUnit.Case, async: true
  alias Absinthe.SocketTest.Endpoint

  setup do
    http_port = Endpoint.http_port()
    socket_url = "ws://localhost:#{http_port}/socket/websocket"
    {:ok, http_port: http_port, socket_url: socket_url}
  end

  test "push/3 pushes a doc over the socket and receives a reply", %{socket_url: uri} do
    query = """
    query Creator($repository: Repository!) {
      creator(repository: $repository) {
        name
      }
    }
    """

    client = start_supervised!({Absinthe.Socket, uri: uri})

    :ok =
      Absinthe.Socket.push(client, query,
        variables: %{"repository" => "ABSINTHE"},
        ref: ref = make_ref()
      )

    assert_receive %Absinthe.Socket.Reply{
      ref: ^ref,
      result: {:ok, %{"data" => %{"creator" => %{"name" => "Ben Wilson"}}}}
    }
  end
end
