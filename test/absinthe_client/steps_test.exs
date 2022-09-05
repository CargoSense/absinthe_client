defmodule AbsintheClient.StepsTest do
  use ExUnit.Case, async: true

  doctest AbsintheClient.Steps

  defmodule EchoJSON do
    def call(conn, _) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json; charset=utf-8")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  test "KeyError when the query option is not set" do
    assert_raise KeyError, "key :query not found in: %{}", fn ->
      Req.new(method: :post)
      |> AbsintheClient.attach()
      |> Req.request!()
    end
  end

  test "GET requests raise ArgumentError" do
    assert_raise ArgumentError, "invalid request method, expected :post, got: :get", fn ->
      Req.new()
      |> AbsintheClient.attach()
      |> Req.request!(query: "query GetItem{ getItem{ id } }")
    end
  end

  test "POST requests send JSON-encoded operations" do
    resp =
      [plug: EchoJSON]
      |> Req.new()
      |> AbsintheClient.attach()
      |> Req.post!(query: "query GetItem{ getItem{ id } }")

    assert resp.body == %{"query" => "query GetItem{ getItem{ id } }", "variables" => %{}}

    resp =
      [plug: EchoJSON]
      |> Req.new()
      |> AbsintheClient.attach()
      |> Req.post!(query: "query GetItem{ getItem{ id } }", variables: %{"foo" => "bar"})

    assert resp.body == %{
             "query" => "query GetItem{ getItem{ id } }",
             "variables" => %{"foo" => "bar"}
           }
  end
end
