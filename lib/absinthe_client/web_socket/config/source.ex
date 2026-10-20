defmodule AbsintheClient.WebSocket.Config.Source do
  # The request a socket rebuilds its configuration from. Req redacts the
  # :auth option and the authorization header, but :connect_params can carry
  # a token as a plain map, so Inspect hides it from crash reports.
  @moduledoc false

  @type t :: %__MODULE__{request: Req.Request.t()}
  defstruct [:request]

  @spec new(Req.Request.t()) :: t()
  def new(%Req.Request{} = request), do: %__MODULE__{request: request}

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{request: request}, opts) do
      request = update_in(request.options, &redact/1)
      concat(["#AbsintheClient.WebSocket.Config.Source<", to_doc(request, opts), ">"])
    end

    defp redact(%{connect_params: params} = options) when is_map(params),
      do: %{options | connect_params: "***"}

    defp redact(options), do: options
  end
end
