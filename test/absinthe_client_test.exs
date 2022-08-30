defmodule AbsintheClientUnitTest do
  use ExUnit.Case, async: true
  alias Absinthe.SocketTest.Endpoint

  doctest AbsintheClient

  setup do
    {:ok, url: Endpoint.graphql_url(), subscription_url: Endpoint.subscription_url()}
  end

  @creator_query_graphql """
  query Creator($repository: Repository!) {
    creator(repository: $repository) {
      name
    }
  }
  """

  @repo_comment_mutation """
  mutation RepoCommentMutation($input: RepoCommentInput!){
    repoComment(input: $input) {
       id
    }
  }
  """

  @repo_comment_subscription """
  subscription RepoCommentSubscription($repository: Repository!){
    repoCommentSubscribe(repository: $repository){
      id
      commentary
    }
  }
  """

  test "query!/2 with a graphql query string", %{url: url} do
    assert AbsintheClient.query!(url, query: @creator_query_graphql).errors == [
             %{
               "locations" => [%{"column" => 11, "line" => 2}],
               "message" =>
                 "In argument \"repository\": Expected type \"Repository!\", found null."
             },
             %{
               "locations" => [%{"column" => 15, "line" => 1}],
               "message" => "Variable \"repository\": Expected non-null, found null."
             }
           ]

    response =
      AbsintheClient.query!(url,
        query: @creator_query_graphql,
        variables: %{"repository" => "PHOENIX"}
      )

    assert response.operation.operation_type == :query
    assert response.operation.query == @creator_query_graphql
    assert response.data == %{"creator" => %{"name" => "Chris McCord"}}
  end

  test "mutate!/1 with a url", %{url: url, test: test} do
    response =
      AbsintheClient.mutate!(
        url,
        query: @repo_comment_mutation,
        variables: %{
          "input" => %{
            "repository" => "PHOENIX",
            "commentary" => Atom.to_string(test)
          }
        }
      )

    assert response.operation.operation_type == :mutation
    assert response.data["repoComment"]["id"]
  end

  test "mutate!/1 with a Request", %{test: test, url: url} do
    request = AbsintheClient.new(url: url)

    response =
      AbsintheClient.mutate!(request,
        query: @repo_comment_mutation,
        variables: %{
          "input" => %{
            "repository" => "PHOENIX",
            "commentary" => Atom.to_string(test)
          }
        }
      )

    assert response.operation.operation_type == :mutation
    assert response.data["repoComment"]["id"]
  end

  test "request!/2 with a Request", %{url: url} do
    request = [url: url] |> AbsintheClient.new()

    assert AbsintheClient.request!(request,
             query: "query { creator(repository: FOO) { name } }"
           ).errors ==
             [
               %{
                 "locations" => [
                   %{
                     "column" => 17,
                     "line" => 1
                   }
                 ],
                 "message" => "Argument \"repository\" has invalid value FOO."
               }
             ]

    response =
      AbsintheClient.request!(request,
        query: @creator_query_graphql,
        variables: %{"repository" => "PHOENIX"}
      )

    refute response.operation.operation_type
    assert response.operation.query == @creator_query_graphql
    assert response.data == %{"creator" => %{"name" => "Chris McCord"}}
  end

  describe "subscribe!/1 (WebSocket)" do
    test "subscribe!/1 with a url", %{subscription_url: subscription_url} do
      response =
        AbsintheClient.subscribe!(
          subscription_url,
          query: @repo_comment_subscription,
          variables: %{"repository" => "PHOENIX"}
        )

      assert response.operation.operation_type == :subscription
      refute response.data
      refute response.errors
    end

    test "subscribe!/1 with a Request", %{subscription_url: subscription_url} do
      client = AbsintheClient.new(url: subscription_url)

      response =
        AbsintheClient.subscribe!(
          client,
          query: @repo_comment_subscription,
          variables: %{"repository" => "PHOENIX"}
        )

      assert response.operation.operation_type == :subscription
      refute response.data
      refute response.errors
    end
  end
end
