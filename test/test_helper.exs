Application.put_env(:absinthe_socket, Absinthe.SocketTest.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 8001],
  secret_key_base: "HOJE5xctETrtYS5RfAG+Ivz35iKH7JXyVz7MN6ExwmjIDVMVXoMbpHrp8ZEt++cK",
  check_origin: false,
  pubsub_server: Absinthe.SocketTest.PubSub,
  server: true
)

defmodule Absinthe.SocketTest.Schema do
  use Absinthe.Schema

  @desc "An item"
  object :item do
    field(:id, :id)
    field(:name, :string)
  end

  # Example data
  @items %{
    "foo" => %{id: "foo", name: "Foo"},
    "bar" => %{id: "bar", name: "Bar"}
  }

  query do
    field :item, :item do
      arg(:id, non_null(:id))

      resolve(fn %{id: item_id}, _ ->
        {:ok, @items[item_id]}
      end)
    end
  end
end

defmodule Absinthe.SocketTest.UserSocket do
  use Phoenix.Socket

  use Absinthe.Phoenix.Socket,
    schema: Absinthe.SocketTest.Schema

  @impl Phoenix.Socket
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl Phoenix.Socket
  def id(_socket), do: nil
end

defmodule Absinthe.SocketTest.Endpoint do
  use Phoenix.Endpoint, otp_app: :absinthe_socket
  use Absinthe.Phoenix.Endpoint

  plug Plug.Session,
    store: :cookie,
    key: "_absinthe_socket_key",
    signing_salt: "tr9gMQxErRYmg4"

  socket "/socket", Absinthe.SocketTest.UserSocket,
    websocket: true,
    longpoll: false

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Absinthe.Plug, schema: Absinthe.SocketTest.Schema

  def http_port do
    __MODULE__.config(:http)[:port]
  end
end

Supervisor.start_link(
  [
    {Phoenix.PubSub, name: Absinthe.SocketTest.PubSub, adapter: Phoenix.PubSub.PG2},
    Absinthe.SocketTest.Endpoint,
    {Absinthe.Subscription, Absinthe.SocketTest.Endpoint}
  ],
  strategy: :one_for_one
)

ExUnit.configure(assert_receive_timeout: 250, refute_receive_timeout: 300)
ExUnit.start(exclude: :integration)
