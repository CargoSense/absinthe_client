Application.put_env(:absinthe_socket, Absinthe.SocketTest.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 8001],
  secret_key_base: "HOJE5xctETrtYS5RfAG+Ivz35iKH7JXyVz7MN6ExwmjIDVMVXoMbpHrp8ZEt++cK",
  check_origin: false,
  pubsub_server: Absinthe.SocketTest.PubSub,
  render_errors: [view: Absinthe.SocketTest.ErrorView],
  server: true
)

defmodule Absinthe.SocketTest.DB do
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

  @repo_comments_table :absinthe_socket_test_db_repo_comments

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

defmodule Absinthe.SocketTest.Schema do
  use Absinthe.Schema
  alias Absinthe.SocketTest.DB

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
    Absinthe.SocketTest.DB,
    {Phoenix.PubSub, name: Absinthe.SocketTest.PubSub, adapter: Phoenix.PubSub.PG2},
    Absinthe.SocketTest.Endpoint,
    {Absinthe.Subscription, Absinthe.SocketTest.Endpoint}
  ],
  strategy: :one_for_one
)

ExUnit.configure(assert_receive_timeout: 550, refute_receive_timeout: 600)
ExUnit.start(exclude: :integration)
