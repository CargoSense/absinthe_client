defmodule AbsintheClientUnitTest do
  use ExUnit.Case, async: true
  alias AbsintheClientTest.Endpoint

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
    assert AbsintheClient.query!(url, @creator_query_graphql).body == %{
             "errors" => [
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
           }

    response = AbsintheClient.query!(url, {@creator_query_graphql, %{"repository" => "PHOENIX"}})

    assert response.private.operation.operation_type == :query
    assert response.private.operation.query == @creator_query_graphql
    assert response.body == %{"data" => %{"creator" => %{"name" => "Chris McCord"}}}
  end

  test "mutate!/1 with a url", %{url: url, test: test} do
    response =
      AbsintheClient.mutate!(
        url,
        {@repo_comment_mutation,
         %{
           "input" => %{
             "repository" => "PHOENIX",
             "commentary" => Atom.to_string(test)
           }
         }}
      )

    assert response.private.operation.operation_type == :mutation
    assert response.body["data"]["repoComment"]["id"]
  end

  test "mutate!/1 with a Request", %{test: test, url: url} do
    request = AbsintheClient.new(url: url)

    response =
      AbsintheClient.mutate!(
        request,
        {@repo_comment_mutation,
         %{
           "input" => %{
             "repository" => "PHOENIX",
             "commentary" => Atom.to_string(test)
           }
         }}
      )

    assert response.private.operation.operation_type == :mutation
    assert response.body["data"]["repoComment"]["id"]
  end

  test "request!/2 with a Request", %{url: url} do
    request = [url: url] |> AbsintheClient.new()

    assert AbsintheClient.request!(
             request,
             operation: "query { creator(repository: FOO) { name } }"
           ).body ==
             %{
               "errors" => [
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
             }

    response =
      AbsintheClient.request!(request,
        operation: {@creator_query_graphql, %{"repository" => "PHOENIX"}}
      )

    assert response.private.operation.operation_type == :query
    assert response.private.operation.query == @creator_query_graphql
    assert response.body == %{"data" => %{"creator" => %{"name" => "Chris McCord"}}}
  end

  describe "subscribe!/2 (WebSocket)" do
    test "subscribe!/2 with a url", %{subscription_url: subscription_url} do
      response =
        AbsintheClient.subscribe!(
          subscription_url,
          {@repo_comment_subscription, %{"repository" => "PHOENIX"}}
        )

      assert response.private.operation.operation_type == :subscription
      assert %{"data" => %{"subscriptionId" => subscription_id}} = response.body
      assert subscription_id =~ "__absinthe__:doc:"
      refute response.body["errors"]
    end

    test "subscribe!/1 with a Request", %{subscription_url: subscription_url} do
      client = AbsintheClient.new(url: subscription_url)

      response =
        AbsintheClient.subscribe!(
          client,
          {@repo_comment_subscription, %{"repository" => "PHOENIX"}}
        )

      assert response.private.operation.operation_type == :subscription
      assert %{"data" => %{"subscriptionId" => subscription_id}} = response.body
      assert subscription_id =~ "__absinthe__:doc:"
      refute response.body["errors"]
    end
  end
end
