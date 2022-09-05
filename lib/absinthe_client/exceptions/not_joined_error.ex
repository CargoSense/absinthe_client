defmodule AbsintheClient.NotJoinedError do
  @moduledoc """
  Returned by the WebSocket adapter when the client is not
  joined to its control topic.
  """
  defexception message: "not joined"
end
