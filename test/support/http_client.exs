defmodule HTTPClient do
  @spec graphql!(options :: Access.t()) :: term
  def graphql!(opts) do
    opts = Keyword.new(opts)
    {query, opts} = Keyword.pop(opts, :query)

    unless query do
      raise ArgumentError, ":query is required for graphql!/1"
    end

    {params, opts} =
      case Keyword.pop(opts, :variables) do
        {nil, opts} ->
          {%{query: query}, opts}

        {variables, opts} ->
          {%{query: query, variables: variables}, opts}
      end

    body = Jason.encode!(params)

    opts
    |> Keyword.put(:body, body)
    |> Keyword.put(:method, "POST")
    |> Keyword.put_new(:path, "/graphql")
    |> Keyword.update(
      :headers,
      [{"content-type", "application/json"}],
      &(&1 ++ [{"content-type", "application/json"}])
    )
    |> request()
    |> case do
      {:ok, %{body: body}} -> Jason.decode!(body)
      {:error, exc} -> raise exc
    end
  end

  @spec request(options :: Access.t()) ::
          {:ok, %{status: status :: term(), headers: headers :: term(), body: body :: term()}}
          | {:error, exception :: Exception.t()}
  def request(opts) do
    host = opts[:host] || "localhost"
    method = opts[:method] || "GET"
    port = opts[:port] || 4001
    headers = opts[:headers] || []
    body = opts[:body] || nil
    scheme = opts[:scheme] || :http
    path = opts[:path] || raise "the :path key is required to request/1"

    with {:ok, conn} <- Mint.HTTP.connect(scheme, host, port),
         {:ok, conn, request_ref} <- Mint.HTTP.request(conn, method, path, headers, body) do
      receive do
        message ->
          {result, conn} =
            case Mint.HTTP.stream(conn, message) do
              {:ok, conn, responses} ->
                {{:ok, result_for_responses(responses, request_ref)}, conn}

              {:error, conn, reason, _responses} ->
                {{:error, reason}, conn}
            end

          Mint.HTTP.close(conn)

          result
      end
    end
  end

  defp result_for_responses(responses, request_ref) do
    Enum.reduce(responses, %{status: nil, headers: nil, body: nil}, fn
      {:status, ^request_ref, status_code}, acc ->
        %{acc | status: status_code}

      {:headers, ^request_ref, headers}, acc ->
        %{acc | headers: headers}

      {:data, ^request_ref, data}, acc ->
        %{acc | body: data}

      {:done, ^request_ref}, acc ->
        acc
    end)
  end
end
