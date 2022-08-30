defmodule AbsintheClient.OperationTest do
  use ExUnit.Case, async: true
  alias AbsintheClient.Operation

  test "new/1 raises with missing or invalid options" do
    assert_raise ArgumentError, ~r/the :query option is required/, fn ->
      Operation.new([])
    end

    assert_raise ArgumentError, ~r/the :query option is required/, fn ->
      Operation.new(%{})
    end

    assert_raise ArgumentError, ~r/unknown option :foo/, fn ->
      Operation.new(foo: true)
    end

    assert_raise ArgumentError,
                 ~r/expected :query to be a non-empty string, got: ""/,
                 fn ->
                   Operation.new(query: "")
                 end

    assert_raise ArgumentError,
                 ~r/expected :query to be a non-empty string, got: :nope/,
                 fn ->
                   Operation.new(query: :nope)
                 end

    assert_raise ArgumentError,
                 "invalid :operation_type, expected one of :query, :mutation, or :subscription, got: :unknown",
                 fn ->
                   assert Operation.new(operation_type: :unknown, query: "query{}")
                 end
  end

  test "new/1 returns an Operation with optional type hint" do
    assert Operation.new(query: "query{}") == %Operation{
             owner: self(),
             query: "query{}",
             variables: nil
           }

    assert Operation.new(query: "query{}", variables: %{"foo" => "bar"}) == %Operation{
             owner: self(),
             query: "query{}",
             variables: %{"foo" => "bar"}
           }

    assert Operation.new(operation_type: :query, query: "query{}") == %Operation{
             operation_type: :query,
             owner: self(),
             query: "query{}",
             variables: nil
           }

    assert Operation.new(operation_type: :mutation, query: "mutation{}") == %Operation{
             operation_type: :mutation,
             owner: self(),
             query: "mutation{}",
             variables: nil
           }

    assert Operation.new(operation_type: :subscription, query: "subscription{}") ==
             %Operation{
               operation_type: :subscription,
               owner: self(),
               query: "subscription{}",
               variables: nil
             }
  end

  test "merge_options/2 overrides operation_type" do
    assert Operation.merge_options(
             %Operation{operation_type: nil},
             operation_type: :query
           ) == %Operation{operation_type: :query}

    assert Operation.merge_options(
             %Operation{operation_type: :query},
             operation_type: :mutation
           ) == %Operation{operation_type: :mutation}
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
