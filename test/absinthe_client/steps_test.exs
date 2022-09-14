defmodule AbsintheClient.StepsTest do
  use ExUnit.Case, async: true

  defmodule EchoJSON do
    def call(conn, _) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json; charset=utf-8")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  test "request raises ArgumentError for invalid queries" do
    assert_raise ArgumentError, "invalid GraphQL query, expected String.t(), got: nil", fn ->
      Req.new()
      |> AbsintheClient.attach(query: nil)
      |> Req.request!()
    end

    assert_raise ArgumentError, "invalid GraphQL query, expected String.t(), got: 42", fn ->
      Req.new()
      |> AbsintheClient.attach(query: 42)
      |> Req.request!()
    end

    assert_raise ArgumentError,
                 "invalid GraphQL query, expected String.t(), got: %{foo: :bar}",
                 fn ->
                   Req.new()
                   |> AbsintheClient.attach(query: %{foo: :bar})
                   |> Req.request!()
                 end
  end

  test "requests without queries are not encoded" do
    resp =
      [plug: EchoJSON, method: :post]
      |> Req.new()
      |> AbsintheClient.attach()
      |> Req.request!()

    assert resp.body == ""
  end

  test "GET requests are not encoded" do
    resp =
      [plug: EchoJSON]
      |> Req.new()
      |> AbsintheClient.attach()
      |> Req.get!(query: "query GetItem{ getItem{ id } }")

    assert resp.body == ""
  end

  test "POST requests send JSON-encoded operations" do
    resp =
      [plug: EchoJSON]
      |> Req.new()
      |> AbsintheClient.attach()
      |> AbsintheClient.run!("query GetItem{ getItem{ id } }")

    assert resp.body == %{"query" => "query GetItem{ getItem{ id } }", "variables" => %{}}

    resp =
      [plug: EchoJSON]
      |> Req.new()
      |> AbsintheClient.attach()
      |> AbsintheClient.run!("query GetItem{ getItem{ id } }", variables: %{"foo" => "bar"})

    assert resp.body == %{
             "query" => "query GetItem{ getItem{ id } }",
             "variables" => %{"foo" => "bar"}
           }
  end
end
