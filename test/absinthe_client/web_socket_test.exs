defmodule AbsintheClient.WebSocketTest do
  use ExUnit.Case

  doctest AbsintheClient.WebSocket.Push

  defmodule Listener do
    use GenServer

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    def call(pid, fun) when is_function(fun, 1) do
      GenServer.call(pid, {:call, fun})
    end

    def init(%Req.Request{} = req) do
      ws = AbsintheClient.WebSocket.connect!(req)
      {:ok, %{req: req, ws: ws}}
    end

    def handle_call({:call, fun}, _, state) when is_function(fun, 1) do
      fun.(state)
    end
  end

  setup do
    {:ok, socket_url: AbsintheClientTest.Endpoint.subscription_url()}
  end

  test "push/2 pushes a doc over the socket and receives a reply", %{socket_url: uri} do
    query = """
    query Creator($repository: Repository!) {
      creator(repository: $repository) {
        name
      }
    }
    """

    client =
      start_supervised!({AbsintheClient.WebSocket.AbsintheWs, parent: self(), config: [uri: uri]})

    ref = AbsintheClient.WebSocket.push(client, {query, %{"repository" => "ABSINTHE"}})

    assert_receive %AbsintheClient.WebSocket.Reply{
      ref: ^ref,
      payload: %{"data" => %{"creator" => %{"name" => "Ben Wilson"}}},
      status: :ok
    }
  end

  test "push/2 replies with errors for invalid or unknown operations", %{socket_url: uri} do
    client =
      start_supervised!({AbsintheClient.WebSocket.AbsintheWs, parent: self(), config: [uri: uri]})

    ref = AbsintheClient.WebSocket.push(client, "query { doesNotExist { id } }")

    assert_receive %AbsintheClient.WebSocket.Reply{
      ref: ^ref,
      status: :error,
      payload: %{
        "errors" => [
          %{
            "locations" => [%{"column" => 9, "line" => 1}],
            "message" => "Cannot query field \"doesNotExist\" on type \"RootQueryType\"."
          }
        ]
      }
    }

    ref =
      AbsintheClient.WebSocket.push(
        client,
        """
        query Creator($repository: Repository!) {
          creator(repository: $repository) {
            name
          }
        }
        """
      )

    assert_receive %AbsintheClient.WebSocket.Reply{
      ref: ^ref,
      status: :error,
      payload: %{
        "errors" => [
          %{
            "locations" => [%{"column" => 11, "line" => 2}],
            "message" => "In argument \"repository\": Expected type \"Repository!\", found null."
          },
          %{
            "locations" => [%{"column" => 15, "line" => 1}],
            "message" => "Variable \"repository\": Expected non-null, found null."
          }
        ]
      }
    }
  end

  test "connect/2 re-uses the socket when only credentials change" do
    req = AbsintheClient.attach(Req.new(base_url: "http://localhost:4002"))

    assert {:ok, ws} = AbsintheClient.WebSocket.connect(req, auth: {:bearer, "a"})
    assert {:ok, ^ws} = AbsintheClient.WebSocket.connect(req, auth: {:bearer, "b"})

    assert %{assigns: %{request: %Req.Request{options: %{auth: {:bearer, "b"}}}}} =
             :sys.get_state(ws)
  end

  test "connect/2 starts a socket per URL" do
    req = AbsintheClient.attach(Req.new(base_url: "http://localhost:4002"))

    assert {:ok, ws} = AbsintheClient.WebSocket.connect(req)
    assert {:ok, auth_ws} = AbsintheClient.WebSocket.connect(req, url: "/auth-socket/websocket")

    assert ws != auth_ws
  end

  test "re-runs the auth function before each connection attempt" do
    calls = start_supervised!({Agent, fn -> 0 end})

    token = fn ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> "invalid-token"
        _ -> "valid-token"
      end
    end

    req =
      Req.new(base_url: "http://localhost:4002", auth: fn -> {:bearer, token.()} end)
      |> AbsintheClient.attach()

    assert {:ok, ws} = AbsintheClient.WebSocket.connect(req, url: "/auth-socket/websocket")

    ref = AbsintheClient.WebSocket.push(ws, ~S|{ __type(name: "Repo") { name } }|)

    assert_receive %AbsintheClient.WebSocket.Reply{ref: ^ref, status: :ok}, 2_000
    assert Agent.get(calls, & &1) >= 2
  end

  @tag :capture_log
  test "stops after max rejections and returns the close reason" do
    # Req's default retry must not re-push to the closed socket.
    req =
      Req.new(base_url: "http://localhost:4002", auth: {:bearer, "invalid-token"})
      |> AbsintheClient.attach()

    assert {:ok, ws} =
             AbsintheClient.WebSocket.connect(req,
               url: "/auth-socket/websocket",
               max_rejections: 2
             )

    monitor_ref = Process.monitor(ws)

    assert {:error,
            %AbsintheClient.WebSocket.Error{
              reason: {:closed, {:error, {:upgrade_failure, %{status_code: 403}}}}
            }} =
             Req.request(req, web_socket: ws, graphql: ~S|{ __type(name: "Repo") { name } }|)

    assert_receive %AbsintheClient.WebSocket.Closed{socket: ^ws, ref: nil}
    assert_receive {:DOWN, ^monitor_ref, :process, ^ws, {:shutdown, {:closed, _}}}
  end

  @tag :capture_log
  test "connect/2 after Closed starts a new socket" do
    # Attach a telemetry handler that will pause the closing socket to guarantee
    # that the subsequent connect arrives before the close completes.
    handler_id = {__MODULE__, make_ref()}
    event = [:slipstream, :client, :handle_disconnect, :stop]
    :telemetry.attach(handler_id, event, &__MODULE__.pause_closing_socket/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    req =
      Req.new(base_url: "http://localhost:4002", auth: {:bearer, "invalid-token"})
      |> AbsintheClient.attach(retry: false)

    options = [url: "/auth-socket/websocket", max_rejections: 1]
    assert {:ok, ws} = AbsintheClient.WebSocket.connect(req, options)

    # The test waits for the telemetry handler to say the socket is `:closing`.
    # The telemetry handler then blocks the close while waiting for `:resume`.
    assert_receive %AbsintheClient.WebSocket.Closed{socket: ^ws, ref: nil}
    assert_receive {:closing, ^ws}

    assert {:ok, new_ws} = AbsintheClient.WebSocket.connect(req, options)
    send(ws, :resume)

    refute new_ws == ws
  end

  def pause_closing_socket(_event, _measurements, metadata, parent) do
    case metadata do
      %{return: {:stop, _, _}, socket: %{assigns: %{parent: ^parent}}} ->
        send(parent, {:closing, self()})

        receive do
          :resume -> :ok
        after
          1_000 -> :ok
        end

      _ ->
        :ok
    end
  end

  @tag :capture_log
  test "await_reply/2 returns an error for a push to a closed socket" do
    req =
      Req.new(base_url: "http://localhost:4002", auth: {:bearer, "invalid-token"})
      |> AbsintheClient.attach(retry: false)

    options = [url: "/auth-socket/websocket", max_rejections: 1]
    assert {:ok, ws} = AbsintheClient.WebSocket.connect(req, options)

    monitor_ref = Process.monitor(ws)
    assert_receive {:DOWN, ^monitor_ref, :process, ^ws, {:shutdown, {:closed, _}}}

    ref = AbsintheClient.WebSocket.push(ws, ~S|{ __type(name: "Repo") { name } }|)

    assert {:error, {:closed, _}} = AbsintheClient.WebSocket.await_reply(ref, 1_000)
  end

  @tag :capture_log
  test "Req.request/2 returns an error for a push to a closed socket" do
    req =
      Req.new(base_url: "http://localhost:4002", auth: {:bearer, "invalid-token"})
      |> AbsintheClient.attach(retry: false)

    options = [url: "/auth-socket/websocket", max_rejections: 1]
    assert {:ok, ws} = AbsintheClient.WebSocket.connect(req, options)

    monitor_ref = Process.monitor(ws)
    assert_receive {:DOWN, ^monitor_ref, :process, ^ws, {:shutdown, {:closed, _}}}

    assert {:error, %AbsintheClient.WebSocket.Error{reason: {:closed, :noproc}}} =
             Req.request(req, web_socket: ws, graphql: ~S|{ __type(name: "Repo") { name } }|)
  end

  test "monitors parent and exits on down", %{socket_url: socket_url} do
    client = AbsintheClient.attach(Req.new(base_url: socket_url))
    listener_pid = start_supervised!({Listener, client})

    ws_name =
      Listener.call(listener_pid, fn %{ws: ws} = state ->
        {:reply, ws, state}
      end)

    ref = Process.monitor(ws_name)

    Process.exit(listener_pid, :shutdown)

    assert_receive {:DOWN, ^ref, :process, _, :shutdown}
  end
end
