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

  @query """
  subscription ($repository: Repository!) {
    repoCommentSubscribe(repository: $repository) {
      id
      commentary
    }
  }
  """
  test "refresh token" do
    req =
      Req.new(base_url: "http://localhost:4002/")
      |> AbsintheClient.attach(retry: :never)

    test_pid = self()

    ws =
      req
      |> AbsintheClient.WebSocket.connect!(
        url: "/auth-socket/websocket",
        connect_params: fn connects ->
          if connects > 0 do
            send(test_pid, :reconnect)
            %{"token" => "invalid-token"}
          else
            %{"token" => "valid-token"}
          end
        end
      )

    res =
      Req.request!(req,
        web_socket: ws,
        async: true,
        graphql: {@query, %{"repository" => "ELIXIR"}}
      )

    AbsintheClient.WebSocket.await_reply!(res).payload.__struct__ |> dbg()
  end

  test "sanity" do
    req = Req.new(base_url: "http://localhost:4002") |> AbsintheClient.attach(async: true)

    {:ok, ws} =
      AbsintheClient.WebSocket.connect(req, connect_params: fn -> %{"token" => "valid-token"} end)

    {:ok, res} = Req.request(req, web_socket: ws, graphql: ~S|{ __type(name: "Repo") { name } }|)

    pid = ws |> Process.whereis()

    pid |> Process.alive?() |> dbg()

    :sys.get_state(pid) |> dbg()

    assert AbsintheClient.WebSocket.await_reply!(res).payload["data"] == %{
             "__type" => %{"name" => "Repo"}
           }
  end
end
