defmodule Absinthe.Socket.Integration.SocketTest do
  use ExUnit.Case, async: true
  alias Absinthe.SocketTest.Endpoint

  setup do
    http_port = Endpoint.http_port()
    socket_url = "ws://localhost:#{http_port}/socket/websocket"
    {:ok, http_port: http_port, socket_url: socket_url}
  end

  test "push/3 pushes a doc over the socket and receives a reply", %{socket_url: uri, test: ref} do
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
        ref: ref
      )

    assert_receive %Absinthe.Socket.Reply{
      ref: ^ref,
      result: {:ok, %{"data" => %{"creator" => %{"name" => "Ben Wilson"}}}}
    }
  end

  test "push/3 replies with errors for invalid or unknown operations", %{
    socket_url: uri,
    test: ref
  } do
    client = start_supervised!({Absinthe.Socket, uri: uri})

    :ok = Absinthe.Socket.push(client, "query { doesNotExist { id } }", ref: ref)

    assert_receive %Absinthe.Socket.Reply{
      ref: ^ref,
      result:
        {:error,
         %{
           "errors" => [
             %{
               "locations" => [%{"column" => 9, "line" => 1}],
               "message" => "Cannot query field \"doesNotExist\" on type \"RootQueryType\"."
             }
           ]
         }}
    }

    :ok =
      Absinthe.Socket.push(
        client,
        """
        query Creator($repository: Repository!) {
          creator(repository: $repository) {
            name
          }
        }
        """,
        ref: ref
      )

    assert_receive %Absinthe.Socket.Reply{
      ref: ^ref,
      result:
        {:error,
         %{
           "errors" => [
             %{
               "locations" => [%{"column" => 11, "line" => 2}],
               "message" =>
                 "In argument \"repository\": Expected type \"Repository!\", found null."
             },
             %{
               "locations" => [%{"column" => 15, "line" => 1}],
               "message" => "Variable \"repository\": Expected non-null, found null."
             }
           ]
         }}
    }
  end
end
