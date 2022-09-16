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
    assert_raise ArgumentError,
                 "invalid GraphQL query, expected String.t() or {String.t(), map()}, got: 42",
                 fn ->
                   Req.new(url: "http://example.com")
                   |> AbsintheClient.attach(graphql: 42)
                   |> Req.post!()
                 end

    assert_raise ArgumentError,
                 "invalid GraphQL query, expected String.t() or {String.t(), map()}, got: %{foo: :bar}",
                 fn ->
                   Req.new(url: "http://example.com")
                   |> AbsintheClient.attach(graphql: %{foo: :bar})
                   |> Req.post!()
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
      |> Req.get!(graphql: "query GetItem{ getItem{ id } }")

    assert resp.body == ""
  end

  test "POST requests send JSON-encoded operations" do
    resp =
      [plug: EchoJSON]
      |> Req.new()
      |> AbsintheClient.attach()
      |> Req.post!(graphql: "query GetItem{ getItem{ id } }")

    assert resp.body == %{"query" => "query GetItem{ getItem{ id } }"}

    resp =
      [plug: EchoJSON]
      |> Req.new()
      |> AbsintheClient.attach()
      |> Req.post!(graphql: {"query GetItem{ getItem{ id } }", %{"foo" => "bar"}})

    assert resp.body == %{
             "query" => "query GetItem{ getItem{ id } }",
             "variables" => %{"foo" => "bar"}
           }
  end
end
