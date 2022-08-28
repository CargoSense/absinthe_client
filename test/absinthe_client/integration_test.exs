defmodule AbsintheClient.IntegrationTest do
  use ExUnit.Case

  @moduletag :integration

  test "AbsintheClient.subscribe!/1 (HTTP) raises transport error with timeout" do
    assert_raise Mint.TransportError, "timeout", fn ->
      AbsintheClient.subscribe!(
        Absinthe.SocketTest.Endpoint.graphql_url(),
        query: """
        subscription RepoCommentSubscription($repository: Repository!){
          repoCommentSubscribe(repository: $repository){
            id
            commentary
          }
        }
        """,
        variables: %{"repository" => "ELIXIR"},
        receive_timeout: 1_750
      )
    end
  end
end
