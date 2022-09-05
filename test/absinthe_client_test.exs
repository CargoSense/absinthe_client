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

  test "performing a query operation", %{url: url} do
    req = Req.new(url: url) |> AbsintheClient.attach()

    assert Req.post!(req, query: @creator_query_graphql).body == %{
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

    response =
      Req.post!(req, query: @creator_query_graphql, variables: %{"repository" => "PHOENIX"})

    assert response.body == %{"data" => %{"creator" => %{"name" => "Chris McCord"}}}
  end

  test "performing a mutation operation", %{url: url, test: test} do
    req = Req.new(url: url) |> AbsintheClient.attach()

    response =
      Req.post!(req,
        query: @repo_comment_mutation,
        variables: %{
          "input" => %{
            "repository" => "PHOENIX",
            "commentary" => Atom.to_string(test)
          }
        }
      )

    assert response.body["data"]["repoComment"]["id"]
  end

  describe "subscriptions (WebSocket)" do
    test "performing a subscription operation", %{subscription_url: subscription_url} do
      req = Req.new(url: subscription_url) |> AbsintheClient.attach()

      _socket_name = AbsintheClient.connect(req)

      response =
        AbsintheClient.subscribe!(
          req,
          @repo_comment_subscription,
          variables: %{"repository" => "PHOENIX"}
        )

      assert %{id: subscription_id, ref: ref} = response
      assert subscription_id =~ "__absinthe__:doc:"
      refute ref
    end
  end
end
