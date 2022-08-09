defmodule HTTPClient do
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
