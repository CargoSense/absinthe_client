defmodule AbsintheClient.ReqPluginTest do
  use ExUnit.Case, async: true

  defmodule EchoJSON do
    def call(conn, _) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json; charset=utf-8")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  test "ArgumentError when query is not set" do
    assert_raise ArgumentError, "the :query option is required for GraphQL operations", fn ->
      Req.new()
      |> AbsintheClient.ReqPlugin.attach()
      |> Req.post!()
    end
  end

  test "POST requests send JSON-encoded body" do
    resp =
      [plug: EchoJSON]
      |> Req.new()
      |> AbsintheClient.ReqPlugin.attach()
      |> Req.post!(query: "query GetItem{ getItem{ id } }")

    assert resp.body == %{"query" => "query GetItem{ getItem{ id } }"}

    resp =
      [plug: EchoJSON]
      |> Req.new()
      |> AbsintheClient.ReqPlugin.attach()
      |> Req.post!(query: "query GetItem{ getItem{ id } }", variables: %{"foo" => "bar"})

    assert resp.body == %{
             "query" => "query GetItem{ getItem{ id } }",
             "variables" => %{"foo" => "bar"}
           }
  end
end
