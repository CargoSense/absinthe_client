defmodule AbsintheClient.WebSocket.Config do
  # Builds the Slipstream configuration from a Req request.
  @moduledoc false
  alias Req.Request

  @type t :: %__MODULE__{key: term(), slipstream: keyword()}
  defstruct [:key, :slipstream]

  @doc """
  Runs the request pipeline and returns the WebSocket configuration.
  """
  @spec build(Request.t()) :: {:ok, t()} | {:error, Exception.t()}
  def build(%Request{} = request) do
    case Req.request(%{request | adapter: &__MODULE__.run/1}) do
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

    case Slipstream.Configuration.validate(slipstream) do
      {:ok, _} ->
        config = %__MODULE__{key: key, slipstream: slipstream}

        {req, Req.Response.new(body: config)}

      {:error, exception} ->
        {req, exception}
    end
  end

  defp put_connect_params(%Request{} = req) do
    case Map.fetch(req.options, :connect_params) do
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

  defp maybe_put_auth_params(%Request{} = req) do
    case Map.fetch(req.options, :auth) do
      {:ok, {:bearer, token}} ->
        put_connect_params(req, %{"Authorization" => "Bearer #{token}"})

      _ ->
        req
    end
  end
end
