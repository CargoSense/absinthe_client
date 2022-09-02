defmodule AbsintheClient.RequestTest do
  use ExUnit.Case, async: true

  doctest AbsintheClient.Request

  defmodule EchoJSON do
    def call(conn, _) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json; charset=utf-8")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  test "ArgumentError when query is not set" do
    assert_raise ArgumentError, "expected :query to be set, but it was not", fn ->
      AbsintheClient.new() |> AbsintheClient.request!()
    end
  end

  test "GET requests raise ArgumentError" do
    client = AbsintheClient.new()

    assert_raise ArgumentError, "only :post requests are currently supported, got: :get", fn ->
      %{client | method: :get}
      |> AbsintheClient.request!(query: "query GetItem{ getItem{ id } }")
    end
  end

  test "POST requests send JSON-encoded operations" do
    resp =
      [plug: EchoJSON]
      |> AbsintheClient.new()
      |> Req.Request.put_private(
        :operation,
        AbsintheClient.Operation.new(query: "query GetItem{ getItem{ id } }")
      )
      |> Req.post!()

    assert resp.body == %{"query" => "query GetItem{ getItem{ id } }"}

    resp =
      [plug: EchoJSON]
      |> AbsintheClient.new()
      |> Req.Request.put_private(
        :operation,
        AbsintheClient.Operation.new(
          query: "query GetItem{ getItem{ id } }",
          variables: %{"foo" => "bar"}
        )
      )
      |> Req.post!()

    assert resp.body == %{
             "query" => "query GetItem{ getItem{ id } }",
             "variables" => %{"foo" => "bar"}
           }

    resp =
      [plug: EchoJSON]
      |> AbsintheClient.new()
      |> Req.Request.put_private(
        :operation,
        AbsintheClient.Operation.new(
          query: "query GetItem{ getItem{ id } }",
          variables: %{}
        )
      )
      |> Req.post!()

    assert resp.body == %{"query" => "query GetItem{ getItem{ id } }"}
  end

  test "response contains the operation" do
    operation = AbsintheClient.Operation.new(query: "query GetItem{ getItem{ id } }")

    {:ok, response} =
      [plug: EchoJSON]
      |> AbsintheClient.new()
      |> Req.Request.put_private(:operation, operation)
      |> Req.request()

    assert response.private.operation == operation
  end
end
