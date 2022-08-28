defmodule AbsintheClient.Operation do
  @moduledoc """
  Structure representing a GraphQL operation.
  """

  @type t :: %__MODULE__{}
  defstruct [:operation_type, :query, :variables]

  @spec new(Enumerable.t()) :: AbsintheClient.Operation.t()
  def new(options) do
    validate_options(operation = %__MODULE__{}, options)
    operation = struct(operation, options)

    unless operation.query do
      raise ArgumentError, "the :query option is required for GraphQL operations"
    end

    operation
  end

  defp raise_invalid_query_error(query) do
    raise ArgumentError, "expected :query to be a non-empty string, got: #{inspect(query)}"
  end

  @doc false
  def validate_options(%__MODULE__{}, options) do
    validate_options(options, MapSet.new([:operation_type, :query, :variables]))
  end

  def validate_options(%{} = map, options) do
    validate_options(Keyword.new(map), options)
  end

  def validate_options([{:query, value} | rest], registered) do
    case value do
      "" -> raise_invalid_query_error("")
      query when is_binary(query) -> validate_options(rest, registered)
      query -> raise_invalid_query_error(query)
    end
  end

  def validate_options([{:operation_type, value} | rest], registered) do
    case value do
      hint when hint in [:query, :mutation, :subscription] ->
        validate_options(rest, registered)

      other ->
        raise ArgumentError,
              "invalid :operation_type, expected one of :query, :mutation, or :subscription, got: #{inspect(other)}"
    end
  end

  def validate_options([{name, _value} | rest], registered) do
    if name in registered do
      validate_options(rest, registered)
    else
      raise ArgumentError, "unknown option #{inspect(name)}"
    end
  end

  def validate_options([], _registered) do
    :ok
  end

  @doc false
  @spec merge_options(AbsintheClient.Operation.t(), Enumerable.t()) ::
          AbsintheClient.Operation.t()
  def merge_options(%__MODULE__{} = operation, options) do
    validate_options(operation, options)

    Map.merge(operation, Map.new(options), fn
      :operation_type, _, new ->
        new

      :variables, nil, new ->
        new

      :variables, old, new ->
        Map.merge(old, new)

      _, _, value ->
        value
    end)
  end

  defimpl Jason.Encoder do
    def encode(%{query: _, variables: nil} = op, options) do
      Jason.Encode.map(Map.take(op, [:query]), options)
    end

    def encode(%{query: _, variables: %{} = vars} = op, options) when map_size(vars) == 0 do
      Jason.Encode.map(Map.take(op, [:query]), options)
    end

    def encode(%{query: _, variables: _} = op, options) do
      Jason.Encode.map(Map.take(op, [:query, :variables]), options)
    end
  end
end
