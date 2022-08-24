defmodule AbsintheClientUnitTest do
  use ExUnit.Case, async: true
  alias Absinthe.SocketTest.Endpoint

  doctest AbsintheClient

  setup do
    {:ok, url: Endpoint.graphql_url()}
  end

  @creator_query_graphql """
  query Creator($repository: Repository!) {
    creator(repository: $repository) {
      name
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

    assert AbsintheClient.query!(url,
             query: @creator_query_graphql,
             variables: %{"repository" => "PHOENIX"}
           ).data == %{"creator" => %{"name" => "Chris McCord"}}
  end

  test "request!/2 with a Req.Request", %{url: url} do
    request = [url: url] |> Req.new() |> AbsintheClient.Request.attach()

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

    assert AbsintheClient.request!(request,
             query: @creator_query_graphql,
             variables: %{"repository" => "PHOENIX"}
           ).data == %{"creator" => %{"name" => "Chris McCord"}}
  end
end
