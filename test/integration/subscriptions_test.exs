Code.require_file("../support/http_client.exs", __DIR__)

defmodule Absinthe.Socket.Integration.SubscriptionsTest do
  use ExUnit.Case, async: true

  defmodule CommentSubscriber do
    use GenServer

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    def subscribe(pid, {:repo, _} = arg) do
      GenServer.call(pid, {:subscribe, arg})
    end

    def trigger_disconnect(pid) do
      GenServer.call(pid, :trigger_disconnect)
    end

    ## Private

    def init({socket_url, parent}) do
      {:ok, pid} = Absinthe.Socket.start_link(uri: socket_url)

      state = %{
        parent: parent,
        socket: pid,
        subscription_id_to_ref: %{}
      }

      {:ok, state}
    end

    def handle_info(%Absinthe.Socket.Reply{ref: ref, result: result}, state) do
      {:ok, %{"subscriptionId" => subscription_id}} = result

      send(state.parent, {:subscription_reply, ref, subscription_id})

      new_subs = Map.put(state.subscription_id_to_ref, subscription_id, ref)

      {:noreply, %{state | subscription_id_to_ref: new_subs}}
    end

    def handle_info(%Absinthe.Subscription.Data{id: subscription_id} = data, state) do
      %{"data" => %{"repoCommentSubscribe" => object}} = data.result

      case Map.fetch(state.subscription_id_to_ref, subscription_id) do
        {:ok, ref} ->
          send(state.parent, {:subscription_data, ref, subscription_id, object})
          {:noreply, state}

        :error ->
          {:noreply, state}
      end
    end

    def handle_call({:subscribe, {:repo, name}}, _, state) do
      Absinthe.Socket.push(
        state.socket,
        """
        subscription RepoCommentSubscription($repository: Repository!){
          repoCommentSubscribe(repository: $repository){
            id
            commentary
          }
        }
        """,
        ref: ref = make_ref(),
        variables: %{"repository" => name}
      )

      {:reply, {:ok, ref}, state}
    end

    def handle_call(:trigger_disconnect, _from, state) do
      %Slipstream.Socket{} = socket = :sys.get_state(state.socket)
      ref = Process.monitor(socket.channel_pid)
      Slipstream.disconnect(socket)

      receive do
        {:DOWN, ^ref, :process, _object, _reason} ->
          {:reply, :ok, state}
      after
        1_000 ->
          raise RuntimeError,
                "expected channel pid #{inspect(socket.channel_pid)} to be killed, but it was not"
      end
    end
  end

  defmodule CommentPublisher do
    use GenServer

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    def init({port, parent}), do: {:ok, %{port: port, parent: parent}}

    def publish!(pid, opts) do
      opts = Keyword.new(opts)

      {commentary, opts} = Keyword.pop(opts, :commentary)

      unless commentary do
        raise ArgumentError, "the :commentary option is required for publish/1"
      end

      {repository, opts} = Keyword.pop(opts, :repository)

      unless repository do
        raise ArgumentError, "the :repository option is required for publish/1"
      end

      query = """
      mutation RepoCommentMutation($input: RepoCommentInput!){
        repoComment(input: $input) {
           id
        }
      }
      """

      opts =
        opts
        |> Keyword.put(:query, query)
        |> Keyword.put(:variables, %{
          "input" => %{
            "repository" => repository,
            "commentary" => commentary
          }
        })

      GenServer.call(pid, {:publish!, opts})
    end

    def handle_call({:publish!, opts}, _, state) do
      response =
        opts
        |> Keyword.put(:port, state.port)
        |> HTTPClient.graphql!()
        |> Kernel.then(&get_in(&1, ["data", "repoComment", "id"]))

      {:reply, response, state}
    end
  end

  setup do
    http_port = Absinthe.SocketTest.Endpoint.http_port()
    socket_url = "ws://localhost:#{http_port}/socket/websocket"

    {:ok, %{http_port: http_port, socket_url: socket_url}}
  end

  test "pushes a subscription to the server and receives a success reply",
       %{socket_url: socket_url} do
    pid = start_supervised!({CommentSubscriber, {socket_url, self()}})

    {:ok, ref} = CommentSubscriber.subscribe(pid, {:repo, "ELIXIR"})

    assert_receive {:subscription_reply, ^ref, subscription_id}

    assert subscription_id
  end

  @tag :skip
  test "pushes a invalid query to the server and receives an error reply"
  # - [ ] Push an invalid subscription to the server
  # - [ ] assert we receive a reply with an error
  # - [ ] Push a mutation to the server
  # - [ ] assert we received a reply with an error (invalid query?)
  # - [ ] Push a query to the server
  # - [ ] assert we received a reply with an error
  # - [ ] Push multiple root operations without an operationName
  # - [ ] assert we received a reply with an error

  test "forwards a subscription message to the subscribed caller",
       %{http_port: port, socket_url: socket_url} do
    subscriber_pid = start_supervised!({CommentSubscriber, {socket_url, self()}})

    repo = "ABSINTHE"
    {:ok, ref} = CommentSubscriber.subscribe(subscriber_pid, {:repo, repo})

    assert_receive {:subscription_reply, ^ref, subscription_id}

    publisher_pid = start_supervised!({CommentPublisher, {port, self()}})
    comment_id = CommentPublisher.publish!(publisher_pid, repository: repo, commentary: "hi")

    assert_receive {:subscription_data, ^ref, ^subscription_id,
                    %{"id" => ^comment_id, "commentary" => "hi"}}
  end

  @tag :skip
  test "drops replies from invalid or unknown subscriptions"
  # - [ ] Trigger a subscription message on the server
  # - [ ] assert we receive a reply for this subscription
  # - [ ] Unsubscribe from the subscription topic
  # - [ ] refute that the subscription data was received by the caller (aka self())

  test "rejoining active subscription on reconnect",
       %{http_port: port, socket_url: socket_url, test: test} do
    publisher_pid = start_supervised!({CommentPublisher, {port, self()}})
    subscriber_pid = start_supervised!({CommentSubscriber, {socket_url, self()}})

    repo = "PHOENIX"
    text = "#{test}"

    {:ok, ref} = CommentSubscriber.subscribe(subscriber_pid, {:repo, repo})
    assert_receive {:subscription_reply, ^ref, subscription_id}

    comment_id = CommentPublisher.publish!(publisher_pid, repository: repo, commentary: text)

    assert_receive {:subscription_data, ^ref, ^subscription_id,
                    %{"id" => ^comment_id, "commentary" => ^text}}

    :ok = CommentSubscriber.trigger_disconnect(subscriber_pid)

    assert_receive {:subscription_reply, ^ref, new_subscription_id}

    new_text = String.duplicate(text, 2)

    new_comment_id =
      CommentPublisher.publish!(publisher_pid, repository: repo, commentary: new_text)

    assert_receive {:subscription_data, ^ref, ^new_subscription_id,
                    %{"id" => ^new_comment_id, "commentary" => ^new_text}}
  end
end
