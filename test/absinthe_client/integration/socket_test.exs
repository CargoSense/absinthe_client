defmodule AbsintheClient.Integration.WebSocketTest do
  use ExUnit.Case, async: true

  defmodule Listener do
    use GenServer

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    def call(pid, fun) when is_function(fun, 1) do
      GenServer.call(pid, {:call, fun})
    end

    def init(%Req.Request{} = req) do
      {:ok, AbsintheClient.WebSocket.connect(req)}
    end

    def handle_call({:call, fun}, _, state) when is_function(fun, 1) do
      fun.(state)
    end
  end

  setup do
    {:ok, socket_url: AbsintheClientTest.Endpoint.subscription_url()}
  end

  test "push/3 pushes a doc over the socket and receives a reply", %{socket_url: uri, test: ref} do
    query = """
    query Creator($repository: Repository!) {
      creator(repository: $repository) {
        name
      }
    }
    """

    client = start_supervised!({AbsintheClient.WebSocket, {self(), uri: uri}})

    :ok =
      AbsintheClient.WebSocket.push(client, query,
        variables: %{"repository" => "ABSINTHE"},
        ref: ref
      )

    assert_receive %AbsintheClient.WebSocket.Reply{
      ref: ^ref,
      result: {:ok, %{"data" => %{"creator" => %{"name" => "Ben Wilson"}}}}
    }
  end

  test "push/3 replies with errors for invalid or unknown operations", %{
    socket_url: uri,
    test: ref
  } do
    client = start_supervised!({AbsintheClient.WebSocket, {self(), uri: uri}})

    :ok = AbsintheClient.WebSocket.push(client, "query { doesNotExist { id } }", ref: ref)

    assert_receive %AbsintheClient.WebSocket.Reply{
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
      AbsintheClient.WebSocket.push(
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

    assert_receive %AbsintheClient.WebSocket.Reply{
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

  test "monitors parent and exits on down", %{socket_url: socket_url} do
    listener_pid = start_supervised!({Listener, Req.new(url: socket_url)})

    socket_pid =
      Listener.call(listener_pid, fn socket_pid ->
        {:reply, socket_pid, socket_pid}
      end)

    socket_monitor = Process.monitor(socket_pid)

    Process.exit(listener_pid, :shutdown)

    assert_receive {:DOWN, ^socket_monitor, :process, _, :shutdown}
  end
end
