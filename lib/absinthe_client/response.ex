defmodule AbsintheClient.Response do
  @moduledoc """
  Structure for response data from GraphQL.

  The following fields are available:

  * `:status` - HTTP status code.

  * `:headers` - HTTP headers

  * `:data`- Response data from the GraphQL operation.
    Note that `data` will be `nil` when errors occur prior
    to resolution.

  * `:errors` - An optional list of GraphQL errors. Note
    that `errors` will be `nil` for successful operations.
  """
  @type t :: %__MODULE__{}
  defstruct [:status, :headers, :data, :errors]
end
