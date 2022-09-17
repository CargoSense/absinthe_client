defmodule AbsintheClient.Utils do
  @moduledoc false

  @doc """
  Converts a graphql arg into a map suitable for JSON encoding.

  ## Examples

      iex> AbsintheClient.Utils.request_json!("query{...}")
      %{query: "query{...}"}

      iex> AbsintheClient.Utils.request_json!({"query{...}", nil})
      %{query: "query{...}"}

      iex> AbsintheClient.Utils.request_json!({"query{...}", %{a: :b}})
      %{query: "query{...}", variables: %{a: :b}}

      iex> AbsintheClient.Utils.request_json!(:foo)
      ** (ArgumentError) invalid GraphQL query, expected String.t() or {String.t(), map()}, got: :foo
  """
  def request_json!(graphql) do
    case query_vars!(graphql) do
      {query, nil} -> %{query: query}
      {query, variables} -> %{query: query, variables: variables}
    end
  end

  @doc """
  Normalizes a `graphql` argument into a `{query, variables}` tuple.

  ## Examples

      iex> AbsintheClient.Utils.query_vars!("query{...}")
      {"query{...}", nil}

      iex> AbsintheClient.Utils.query_vars!({"query{...}", nil})
      {"query{...}", nil}

      iex> AbsintheClient.Utils.query_vars!({"query{...}", %{a: :b}})
      {"query{...}", %{a: :b}}

      iex> AbsintheClient.Utils.query_vars!(:foo)
      ** (ArgumentError) invalid GraphQL query, expected String.t() or {String.t(), map()}, got: :foo
  """
  def query_vars!(query) when is_binary(query), do: {query, nil}
  def query_vars!({query, nil} = doc) when is_binary(query), do: doc
  def query_vars!({query, vars} = doc) when is_binary(query) and is_map(vars), do: doc

  def query_vars!(other) do
    raise ArgumentError,
          "invalid GraphQL query, expected String.t() or {String.t(), map()}, got: #{inspect(other)}"
  end
end
