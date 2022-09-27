defmodule AbsintheClient.WebSocket.GraphqlWs do
  @moduledoc false
  use GenServer

  @spec start_link({pid(), config :: Keyword.t()}) :: GenServer.on_start()
  @spec start_link({pid(), config :: Keyword.t(), genserver_options :: GenServer.options()}) ::
          GenServer.on_start()
  def start_link(config) when is_list(config), do: start_link({self(), config, []})
  def start_link({parent, config}) when is_pid(parent), do: start_link({parent, config, []})

  def start_link({parent, config_options, server_options}) do
    with {:ok, config} <- Slipstream.Configuration.validate(config_options) do
      GenServer.start_link(__MODULE__, {parent, config}, server_options)
    end
  end

  @impl GenServer
  def init({_parent, config}) do
    %Slipstream.Configuration{uri: uri, mint_opts: mint_options} = config

    # todo: handle errors
    {:ok, conn} = Mint.HTTP.connect(http_scheme(uri), uri.host, uri.port, mint_options)

    {:ok, %{config: config, conn: conn, uri: uri, ref: nil, ws: nil}, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    %{config: config, conn: conn, uri: uri} = state
    headers = [{"Sec-WebSocket-Protocol", "graphql-transport-ws"}] ++ config.headers

    {:ok, conn, ref} = Mint.WebSocket.upgrade(ws_scheme(uri), conn, path(uri), headers)
    state = %{state | conn: conn, ref: ref}

    http_reply_message = receive(do: (message -> message))

    {:ok, conn, [{:status, ^ref, status}, {:headers, ^ref, resp_headers}, {:done, ^ref}]} =
      Mint.WebSocket.stream(conn, http_reply_message)

    {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, resp_headers)
    state = %{state | conn: conn, ws: ws}

    {:ok, new_state} = push(state, "connection_init")

    {:noreply, new_state}
  end

  defp path(%URI{path: nil}), do: "/graphql"
  defp path(%URI{path: path}), do: path

  defp http_scheme(%URI{scheme: scheme}), do: http_scheme(scheme)
  defp http_scheme("ws"), do: :http
  defp http_scheme("wss"), do: :https
  defp http_scheme(scheme), do: scheme

  defp ws_scheme(%URI{scheme: scheme}), do: ws_scheme(scheme)
  defp ws_scheme("ws"), do: :ws
  defp ws_scheme("wss"), do: :wss
  defp ws_scheme(scheme), do: scheme

  @impl GenServer

  def handle_info(msg, %{ref: ref} = state) do
    case Mint.WebSocket.stream(state.conn, msg) do
      {:ok, conn, [{:data, ^ref, data}]} ->
        {:ok, ws, [frame]} = Mint.WebSocket.decode(state.ws, data)

        case frame do
          {:text, binary} ->
            _decoded = binary |> Jason.decode!() |> dbg()
            {:noreply, state}

          {:ping, _} ->
            {:ok, new_state} = push(state, "pong")

            {:noreply, new_state}
        end

        {:noreply, %{state | conn: conn, ws: ws}}

      {:error, _conn, error, _responses} ->
        # todo: handle errors
        raise error

      :unknown ->
        # This generates the error from the default handle_info/2 callback.

        proc =
          case Process.info(self(), :registered_name) do
            {_, []} -> self()
            {_, name} -> name
          end

        :logger.error(
          %{
            label: {GenServer, :no_handle_info},
            report: %{
              module: __MODULE__,
              message: msg,
              name: proc
            }
          },
          %{
            domain: [:otp, :elixir],
            error_logger: %{tag: :error_msg},
            report_cb: &GenServer.format_report/1
          }
        )

        {:noreply, state}
    end
  end

  defp push(state, type, opts \\ []) do
    %{conn: conn, ws: ws, ref: ref} = state

    with {:ok, conn, ws} <- push(conn, ws, ref, type, opts) do
      {:ok, %{state | conn: conn, ws: ws, ref: ref}}
    end
  end

  defp push(conn, websocket, ref, type, opts) do
    msg = if opts[:payload], do: %{type: type, payload: opts[:payload]}, else: %{type: type}
    push_msg(conn, websocket, ref, Jason.encode!(msg))
  end

  defp push_msg(conn, websocket, ref, msg) when is_binary(msg) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(websocket, {:text, msg}) do
      {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
      {:ok, conn, ws}
    end
  end
end
