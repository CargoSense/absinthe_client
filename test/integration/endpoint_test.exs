Code.require_file("../support/http_client.exs", __DIR__)

defmodule Absinthe.Socket.Integration.EndpointTest do
  # These tests aren't directly related to the Absinthe.Socket functionality–
  # they exist as sanity checks that the GraphQL server is running and accepting connections.
  use ExUnit.Case, async: true
  alias Absinthe.SocketTest.Endpoint

  setup do
    {:ok, http_port: Endpoint.http_port()}
  end

  test "endpoint is running", %{http_port: port} do
    assert {:ok, _} = HTTPClient.request(path: "/graphql", port: port)
  end

  test "endpoint accepts creator query", %{http_port: port} do
    assert graphql!(
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
             graphql!(
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

    assert graphql!(
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

  defp graphql!(opts) do
    opts = Keyword.new(opts)
    {query, opts} = Keyword.pop(opts, :query)

    unless query do
      raise ArgumentError, ":query is required for graphql!/1"
    end

    {body_map, opts} =
      case Keyword.pop(opts, :variables) do
        {nil, opts} ->
          {%{query: query}, opts}

        {variables, opts} ->
          {%{query: query, variables: variables}, opts}
      end

    body = Jason.encode!(body_map)

    opts
    |> Keyword.put(:body, body)
    |> Keyword.put(:method, "POST")
    |> Keyword.put_new(:path, "/graphql")
    |> Keyword.update(
      :headers,
      [{"content-type", "application/json"}],
      &(&1 ++ [{"content-type", "application/json"}])
    )
    |> HTTPClient.request()
    |> case do
      {:ok, %{body: body}} -> Jason.decode!(body)
      {:error, exc} -> raise exc
    end
  end
end
