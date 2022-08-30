defmodule Absinthe.Socket.Integration.SocketTest do
  use ExUnit.Case, async: true
  alias Absinthe.SocketTest.Endpoint

  defmodule Listener do
    use GenServer

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    def call(pid, fun) when is_function(fun, 1) do
      GenServer.call(pid, {:call, fun})
    end

    def init(socket_url) do
      {:ok, socket_pid} =
        DynamicSupervisor.start_child(
          AbsintheClient.SocketSupervisor,
          {Absinthe.Socket, {self(), uri: socket_url}}
        )

      {:ok, socket_pid}
    end

    def handle_call({:call, fun}, _, state) when is_function(fun, 1) do
      fun.(state)
    end
  end

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

    client = start_supervised!({Absinthe.Socket, {self(), uri: uri}})

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
    client = start_supervised!({Absinthe.Socket, {self(), uri: uri}})

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

  test "monitors parent and exits on down", %{socket_url: socket_url} do
    listener_pid = start_supervised!({Listener, socket_url})

    socket_pid =
      Listener.call(listener_pid, fn socket_pid ->
        {:reply, socket_pid, socket_pid}
      end)

    socket_monitor = Process.monitor(socket_pid)

    Process.exit(listener_pid, :shutdown)

    assert_receive {:DOWN, ^socket_monitor, :process, ^socket_pid, :shutdown}
  end
end
