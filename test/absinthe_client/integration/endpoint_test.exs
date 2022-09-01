Code.require_file("../../support/http_client.exs", __DIR__)

defmodule AbsintheClient.Integration.EndpointTest do
  # These tests aren't directly related to the AbsintheClient.WebSocket functionality–
  # they exist as sanity checks that the GraphQL server is running and accepting connections.
  use ExUnit.Case, async: true
  alias AbsintheClientTest.Endpoint

  setup do
    {:ok, http_port: Endpoint.http_port()}
  end

  test "endpoint is running", %{http_port: port} do
    assert {:ok, _} = HTTPClient.request(path: "/graphql", port: port)
  end

  test "endpoint accepts creator query", %{http_port: port} do
    assert HTTPClient.graphql!(
             port: port,
             query: """
             query Creator($repository: Repository!) {
               creator(repository: $repository) {
                 name
               }
             }
             """,
             variables: %{"repository" => "ELIXIR"}
           ) == %{"data" => %{"creator" => %{"name" => "José Valim"}}}
  end

  test "endpoint persists a repoComment mutation", %{http_port: port} do
    assert %{
             "data" => %{
               "repoComment" => %{
                 "id" => comment_id
               }
             }
           } =
             HTTPClient.graphql!(
               port: port,
               query: """
               mutation RepoCommentMutation($input: RepoCommentInput!){
                 repoComment(input: $input) {
                    id
                 }
               }
               """,
               variables: %{
                 "input" => %{
                   "repository" => "ELIXIR",
                   "commentary" => "functional ftw!"
                 }
               }
             )

    assert HTTPClient.graphql!(
             port: port,
             query: """
             query RepoCommentQuery($repo: Repository!, $id: ID!){
               repoComment(repository: $repo, id: $id) {
                  commentary
               }
             }
             """,
             variables: %{
               "repo" => "ELIXIR",
               "id" => comment_id
             }
           ) == %{"data" => %{"repoComment" => %{"commentary" => "functional ftw!"}}}
  end
end
