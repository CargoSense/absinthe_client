defmodule AbsintheClient.Subscription.Data do
  @moduledoc """
  Structure for data sent for a GraphQL subscription.
  """
  @type t :: %__MODULE__{}
  defstruct [:result, :id]
end
