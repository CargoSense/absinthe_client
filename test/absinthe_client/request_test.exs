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

  test "KeyError when operation is not set" do
    assert_raise KeyError, "key :operation not found in: %{}", fn ->
      AbsintheClient.new() |> AbsintheClient.request!()
    end
  end

  test "GET requests raise ArgumentError" do
    client = AbsintheClient.new()

    assert_raise ArgumentError, "only :post requests are currently supported, got: :get", fn ->
      %{client | method: :get}
      |> AbsintheClient.request!(operation: "query GetItem{ getItem{ id } }")
    end
  end

  test "POST requests send JSON-encoded operations" do
    resp =
      [plug: EchoJSON, operation: "query GetItem{ getItem{ id } }"]
      |> AbsintheClient.new()
      |> Req.post!()

    assert resp.body == %{"query" => "query GetItem{ getItem{ id } }"}

    resp =
      [plug: EchoJSON, operation: {"query GetItem{ getItem{ id } }", %{"foo" => "bar"}}]
      |> AbsintheClient.new()
      |> Req.post!()

    assert resp.body == %{
             "query" => "query GetItem{ getItem{ id } }",
             "variables" => %{"foo" => "bar"}
           }

    resp =
      [plug: EchoJSON, operation: {"query GetItem{ getItem{ id } }", %{}}]
      |> AbsintheClient.new()
      |> Req.post!()

    assert resp.body == %{"query" => "query GetItem{ getItem{ id } }"}
  end

  test "response contains the operation" do
    query = "query GetItem{ getItem{ id } }"

    {:ok, response} =
      [plug: EchoJSON, operation: query]
      |> AbsintheClient.new()
      |> Req.request()

    assert response.private.operation ==
             %AbsintheClient.Operation{operation_type: :query, query: query, owner: self()}
  end
end
