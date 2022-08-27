defmodule AbsintheClient.OperationTest do
  use ExUnit.Case, async: true
  alias AbsintheClient.Operation

  test "new/1 raises with missing or invalid options" do
    assert_raise ArgumentError, ~r/the :query option is required/, fn ->
      Operation.new([])
    end

    assert_raise ArgumentError, ~r/the :query option is required/, fn ->
      Operation.new([:query])
    end
  end

  test "new/1 returns an Operation" do
    assert Operation.new(query: "query{}") == %Operation{query: "query{}", variables: nil}

    assert Operation.new(query: "query{}", variables: %{"foo" => "bar"}) == %Operation{
             query: "query{}",
             variables: %{"foo" => "bar"}
           }
  end

  test "merge_options/2 overrides query" do
    assert Operation.merge_options(
             %Operation{query: nil},
             query: "query{1}"
           ) == %Operation{query: "query{1}"}

    assert Operation.merge_options(
             %Operation{query: "query{1}"},
             query: "query{2}"
           ) == %Operation{query: "query{2}"}
  end

  test "merge_options/2 merges variables" do
    assert Operation.merge_options(
             %Operation{variables: nil},
             variables: %{"foo" => "bar"}
           ) == %Operation{variables: %{"foo" => "bar"}}

    assert Operation.merge_options(
             %Operation{variables: %{"foo" => "bar"}},
             variables: %{"foo" => "bat", "count" => 2}
           ) == %Operation{variables: %{"foo" => "bat", "count" => 2}}
  end
end
