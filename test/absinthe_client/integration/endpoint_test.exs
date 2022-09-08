defmodule AbsintheClient.Integration.EndpointTest do
  # These tests aren't directly related to the AbsintheClient functionality–
  # they exist as sanity checks that the GraphQL server is running and accepting connections.
  use ExUnit.Case
  alias AbsintheClientTest.Endpoint

  @moduletag :integration

  setup do
    {:ok, url: Endpoint.graphql_url()}
  end

  test "endpoint is running", %{url: url} do
    assert {:ok, _} = Req.request(url: url)
  end

  test "endpoint accepts creator query", %{url: url} do
    assert Req.post!(
             url,
             json: %{
               query: """
               query Creator($repository: Repository!) {
                 creator(repository: $repository) {
                   name
                 }
               }
               """,
               variables: %{"repository" => "ELIXIR"}
             }
           ).body == %{"data" => %{"creator" => %{"name" => "José Valim"}}}
  end

  test "endpoint persists a repoComment mutation", %{url: url} do
    assert %{
             "data" => %{
               "repoComment" => %{
                 "id" => comment_id
               }
             }
           } =
             Req.post!(
               url,
               json: %{
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
               }
             ).body

    assert Req.post!(
             url,
             json: %{
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
             }
           ).body == %{"data" => %{"repoComment" => %{"commentary" => "functional ftw!"}}}
  end
end
