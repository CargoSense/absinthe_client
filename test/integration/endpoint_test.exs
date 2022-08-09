Code.require_file("../support/http_client.exs", __DIR__)

defmodule Absinthe.Socket.Integration.EndpointTest do
  use ExUnit.Case, async: true
  alias Absinthe.SocketTest.Endpoint

  setup do
    {:ok, http_port: Endpoint.http_port()}
  end

  test "endpoint is running", %{http_port: port} do
    assert {:ok, _} = HTTPClient.request(path: "/graphql", port: port)
  end

  test "endpoint accepts GraphQL documents", %{http_port: port} do
    query = """
    query GetItem($id: ID!) {
      item(id: $id) {
        name
      }
    }
    """

    body = Jason.encode!(%{query: query, variables: %{"id" => "foo"}})

    assert {:ok, %{body: result}} =
             HTTPClient.request(
               path: "/graphql",
               port: port,
               body: body,
               method: "POST",
               headers: [{"content-type", "application/json"}]
             )

    assert Jason.decode!(result) == %{"data" => %{"item" => %{"name" => "Foo"}}}
  end
end
