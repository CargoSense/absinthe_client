defmodule Absinthe.Socket.Reply do
  @moduledoc """
  Defines the structure of a reply to a pushed request.
  """
  @type t :: %__MODULE__{}
  defstruct [:event, :result, :ref]
end

defmodule Absinthe.Socket.Push do
  # Internal structure to track pushed requests.
  @moduledoc false
  defstruct [:event, :pid, :params, :ref]

  def new_doc(query, variables, pid, ref) do
    new("doc", %{query: query, variables: variables}, pid, ref)
  end

  def new(event, params, pid, ref) when is_binary(event) and is_map(params) and is_pid(pid) do
    %__MODULE__{
      event: event,
      params: params,
      pid: pid,
      ref: ref
    }
  end
end
