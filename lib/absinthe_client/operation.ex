defmodule AbsintheClient.Operation do
  @moduledoc """
  Structure representing a GraphQL operation.
  """

  @type t :: %__MODULE__{
          operation_type: :query | :mutation | :subscription,
          owner: pid(),
          query: String.t(),
          ref: nil | term(),
          variables: nil | map()
        }

  defstruct [:operation_type, :owner, :query, :ref, :variables]

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
