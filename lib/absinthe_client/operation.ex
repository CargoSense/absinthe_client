defmodule AbsintheClient.Operation do
  @moduledoc """
  Structure representing a GraphQL operation.
  """

  @type t :: %__MODULE__{}
  defstruct [:type, :name, :query, :variables]

  @spec new(map) :: AbsintheClient.Operation.t()
  def new(options) do
    case Access.fetch(options, :query) do
      {:ok, query} ->
        struct(%__MODULE__{query: query}, options)

      :error ->
        raise ArgumentError, "the :query option is required for GraphQL operations"
    end
  end

  @doc false
  @spec merge_options(AbsintheClient.Operation.t(), Enumerable.t()) ::
          AbsintheClient.Operation.t()
  def merge_options(%__MODULE__{} = operation, options) do
    # todo: validate options
    Map.merge(operation, Map.new(options), fn
      :variables, nil, new ->
        new

      :variables, old, new ->
        Map.merge(old, new)

      _, _, value ->
        value
    end)
  end

  defimpl Jason.Encoder do
    def encode(value, opts) do
      value
      |> Map.take([:query, :variables])
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()
      |> Jason.Encode.map(opts)
    end
  end
end
