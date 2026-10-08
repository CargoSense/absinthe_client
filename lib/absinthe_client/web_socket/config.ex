defmodule AbsintheClient.WebSocket.Config do
  # Builds the Slipstream configuration from a Req request.
  @moduledoc false
  alias Req.Request

  @type t :: %__MODULE__{
          key: term(),
          max_rejections: pos_integer(),
          reconnect_delay: nil | non_neg_integer() | (non_neg_integer() -> non_neg_integer()),
          reconnect: boolean() | (term() -> boolean()),
          slipstream: keyword()
        }
  defstruct [:key, :max_rejections, :reconnect_delay, :slipstream, reconnect: true]

  @default_max_rejections 5

  @doc """
  Runs the request pipeline and returns the WebSocket configuration.

  The request steps run on each call, so function-valued options such
  as `auth: fn -> ... end` produce fresh credentials.
  """
  @spec build(Request.t()) :: {:ok, t()} | {:error, Exception.t()}
  def build(%Request{} = request) do
    case Req.request(%{request | adapter: __MODULE__}) do
      {:ok, %{body: %__MODULE__{} = config}} -> {:ok, config}
      {:error, exception} -> {:error, exception}
    end
  end

  @doc """
  Req adapter that captures the configuration instead of connecting.
  """
  @spec run(Request.t()) :: {Request.t(), Req.Response.t() | Exception.t()}
  def run(%Request{} = req) do
    req = update_in(req.url.scheme, &String.replace(&1, "http", "ws"))
    mint_options = Map.get(req.options, :connect_options, [])
    transport_opts = Keyword.get(mint_options, :transport_opts, [])
    transport_opts = Keyword.put_new(transport_opts, :timeout, 30_000)

    # Credentials are excluded from the key so refreshed tokens re-use the socket.
    key = {URI.to_string(req.url), transport_opts}

    req = put_connect_params(req)

    slipstream = [
      uri: req.url,
      headers: Req.get_headers_list(req),
      mint_opts: [
        protocols: [:http1],
        transport_opts: transport_opts
      ]
    ]

    with {:ok, _} <- Slipstream.Configuration.validate(slipstream),
         {:ok, reconnect} <- validate_reconnect(Map.get(req.options, :reconnect, true)) do
      config = %__MODULE__{
        key: key,
        max_rejections: Map.get(req.options, :max_rejections, @default_max_rejections),
        reconnect_delay: Map.get(req.options, :reconnect_delay),
        reconnect: reconnect,
        slipstream: slipstream
      }

      {req, Req.Response.new(body: config)}
    else
      {:error, exception} -> {req, exception}
    end
  end

  defp validate_reconnect(reconnect) when is_boolean(reconnect) or is_function(reconnect, 1),
    do: {:ok, reconnect}

  defp validate_reconnect(other) do
    {:error,
     %ArgumentError{
       message:
         "expected :reconnect to be a boolean or a 1-arity function, got: #{inspect(other)}"
     }}
  end

  defp put_connect_params(%Request{} = req) do
    case Map.fetch(req.options, :connect_params) do
      {:ok, fun} when is_function(fun, 0) ->
        put_connect_params(req, fun.())

      {:ok, params} ->
        put_connect_params(req, params)

      :error ->
        maybe_put_auth_params(req)
    end
  end

  defp put_connect_params(%Request{} = req, params) do
    encoded = URI.encode_query(params)

    update_in(req.url.query, fn
      nil -> encoded
      query -> query <> "&" <> encoded
    end)
  end

  # The auth step has already run, so the header reflects any auth form Req supports.
  defp maybe_put_auth_params(%Request{} = req) do
    case Request.get_header(req, "authorization") do
      ["Bearer " <> _ = bearer | _] ->
        put_connect_params(req, %{"Authorization" => bearer})

      _ ->
        req
    end
  end
end
