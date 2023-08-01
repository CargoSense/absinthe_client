Application.put_env(:absinthe_client, AbsintheClientTest.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "HOJE5xctETrtYS5RfAG+Ivz35iKH7JXyVz7MN6ExwmjIDVMVXoMbpHrp8ZEt++cK",
  check_origin: false,
  pubsub_server: AbsintheClientTest.PubSub,
  render_errors: [view: AbsintheClientTest.ErrorView],
  server: true
)

# We are stuck with this until we can make Absinthe.Phoenix.Channel logging
# configurable from the outside.
Logger.configure(level: :warn)

defmodule AbsintheClientTest.DB do
  use Supervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @repos %{
    elixir: %{name: "elixir-lang/elixir", creator: nil, comments: nil},
    absinthe: %{name: "absinthe-graphql/absinthe", creator: nil, comments: nil},
    phoenix: %{name: "phoenixframework/phoenix", creator: nil, comments: nil}
  }

  @creators %{
    elixir: %{name: "José Valim"},
    absinthe: %{name: "Ben Wilson"},
    phoenix: %{name: "Chris McCord"}
  }

  @repo_comments_table :absinthe_client_test_db_repo_comments

  @impl true
  def init(_arg) do
    :ets.new(@repo_comments_table, [:set, :public, :named_table])

    children = []

    Supervisor.init(children, strategy: :one_for_one)
  end

  def fetch(:creators, repo) do
    fetch_from_attr(@creators, repo, fn ->
      "no creator for repo '#{inspect(repo)}' was found"
    end)
  end

  def fetch(:repos, name) do
    with {:ok, repo} <-
           fetch_from_attr(@repos, name, fn ->
             "no repo named '#{inspect(name)}' was found"
           end),
         {:ok, creator} <- fetch(:creators, name) do
      # todo: fetch comments
      {:ok, %{repo | creator: creator}}
    end
  end

  def fetch(:repo_comments, %{repository: repo, id: id}) do
    case :ets.lookup(@repo_comments_table, {repo, id}) do
      [{_id, comment}] -> {:ok, comment}
      [] -> {:error, "no comment for repo '#{inspect(repo)}' with ID #{id} was found"}
    end
  end

  def fetch(table, args) do
    error_invalid_args(table, args, :fetch, 2)
  end

  defp fetch_from_attr(attr, key, error_fun) do
    case Map.fetch(attr, key) do
      {:ok, %{} = _item} = okay -> okay
      :error -> {:error, error_fun.()}
    end
  end

  def insert(:repo_comments, %{input: %{repository: repo, commentary: _} = attrs}) do
    comment = Map.put(attrs, :id, "#{System.unique_integer([:positive, :monotonic])}")
    :ets.insert(@repo_comments_table, {{repo, comment.id}, comment})

    {:ok, comment}
  end

  def insert(table, args) do
    error_invalid_args(table, args, :insert, 2)
  end

  defp error_invalid_args(table, args, fun, arity) do
    {:error,
     "invalid args given to #{inspect(__MODULE__)}.#{fun}/#{arity} for table #{inspect(table)}, got: #{inspect(args)}"}
  end
end

defmodule AbsintheClientTest.Schema do
  use Absinthe.Schema
  alias AbsintheClientTest.DB

  enum :repository do
    description "A code repository or project"

    value :elixir, description: "Elixir is a dynamic, functional language"
    value :absinthe, description: "The GraphQL toolkit for Elixir"
    value :phoenix, description: "Peace of mind from prototype to production"
  end

  @desc "A repository"
  object :repo do
    field :name, :string
    field :creator, :creator
  end

  @desc "A repository creator"
  object :creator do
    field :name, :string
  end

  @desc "A repository comment"
  object :repo_comment do
    field :id, :id
    field :commentary, :string
    field :repository, :repository
  end

  input_object :repo_comment_input do
    field :repository, non_null(:repository)
    field :commentary, non_null(:string)
  end

  query do
    field :creator, :creator do
      arg :repository, non_null(:repository)

      resolve fn %{repository: repo}, _ ->
        DB.fetch(:creators, repo)
      end
    end

    field :repo_comment, :repo_comment do
      arg :repository, non_null(:repository)
      arg :id, non_null(:id)

      resolve fn args, _ ->
        DB.fetch(:repo_comments, args)
      end
    end
  end

  mutation do
    field :repo_comment, :repo_comment do
      arg :input, non_null(:repo_comment_input)

      resolve fn _, args, _ ->
        DB.insert(:repo_comments, args)
      end
    end
  end

  subscription do
    field :repo_comment_subscribe, :repo_comment do
      arg :repository, non_null(:repository)

      config fn args, _ ->
        {:ok, topic: args.repository}
      end

      trigger :repo_comment, topic: & &1.repository

      resolve fn comment, _, _ ->
        repo = DB.fetch(:repos, comment.repository)
        {:ok, Map.put(comment, :repo, repo)}
      end
    end
  end
end

defmodule AbsintheClientTest.UserSocket do
  use Phoenix.Socket, log: :debug

  use Absinthe.Phoenix.Socket,
    schema: AbsintheClientTest.Schema

  @impl Phoenix.Socket
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl Phoenix.Socket
  def id(_socket), do: nil
end

defmodule AbsintheClientTest.AuthSocket do
  use Phoenix.Socket, log: :debug

  use Absinthe.Phoenix.Socket,
    schema: AbsintheClientTest.Schema

  @impl Phoenix.Socket
  def connect(params, socket, _conn_info) do
    case fetch_token(params) do
      {:ok, "valid-token"} -> {:ok, socket}
      {:ok, "invalid-token"} -> {:error, :unauthorized}
      _ -> {:error, :bad_request}
    end
  end

  defp fetch_token(%{"Authorization" => "Bearer " <> t}), do: {:ok, t}
  defp fetch_token(%{"token" => t}), do: {:ok, t}
  defp fetch_token(_), do: :error

  @impl Phoenix.Socket
  def id(_socket), do: nil
end

defmodule AbsintheClientTest.Endpoint do
  use Phoenix.Endpoint, otp_app: :absinthe_client
  use Absinthe.Phoenix.Endpoint

  plug Plug.Session,
    store: :cookie,
    key: "_absinthe_client_key",
    signing_salt: "tr9gMQxErRYmg4"

  socket "/socket", AbsintheClientTest.UserSocket,
    websocket: true,
    longpoll: false

  socket "/auth-socket", AbsintheClientTest.AuthSocket,
    websocket: true,
    longpoll: false

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Absinthe.Plug, schema: AbsintheClientTest.Schema

  def http_port, do: __MODULE__.config(:http)[:port]
  def graphql_url, do: __MODULE__.url() <> "/graphql"

  def subscription_url do
    uri = __MODULE__.struct_url()
    URI.to_string(%{uri | scheme: "ws", path: "/socket/websocket"})
  end
end

Supervisor.start_link(
  [
    AbsintheClientTest.DB,
    {Phoenix.PubSub, name: AbsintheClientTest.PubSub, adapter: Phoenix.PubSub.PG2},
    AbsintheClientTest.Endpoint,
    {Absinthe.Subscription, AbsintheClientTest.Endpoint}
  ],
  strategy: :one_for_one
)

ExUnit.configure(assert_receive_timeout: 550, refute_receive_timeout: 600)

unless System.get_env("CI") do
  ExUnit.configure(exclude: :integration)
end

ExUnit.start()
