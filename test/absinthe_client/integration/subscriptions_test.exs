defmodule AbsintheClient.Integration.SubscriptionsTest do
  use ExUnit.Case

  defmodule CommentSubscriber do
    use GenServer

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    def init({client, parent}) do
      socket_name = AbsintheClient.WebSocket.connect!(client)

      {:ok, %{parent: parent, client: client, socket: socket_name}}
    end

    # todo: remove handle_info for reply when clear_subscriptions/1 can be awaited on
    def handle_info(%AbsintheClient.WebSocket.Reply{} = reply, state) do
      %{payload: %AbsintheClient.Subscription{} = subscription} = reply

      send(state.parent, {:subscription_reply, reply.ref, subscription.id})

      {:noreply, state}
    end

    def handle_info(%AbsintheClient.WebSocket.Message{} = msg, state) do
      %{"data" => %{"repoCommentSubscribe" => object}} = msg.payload
      send(state.parent, {:subscription_data, msg.ref, msg.topic, object})
      {:noreply, state}
    end

    def handle_call({:subscribe, {:repo, name}}, _, state) do
      subscription =
        Req.request!(
          state.client,
          web_socket: state.socket,
          graphql: {
            """
            subscription RepoCommentSubscription($repository: Repository!){
              repoCommentSubscribe(repository: $repository){
                id
                commentary
              }
            }
            """,
            %{"repository" => name}
          }
        ).body

      %AbsintheClient.Subscription{id: subscription_id, ref: ref} = subscription

      send(state.parent, {:subscription_reply, ref, subscription_id})

      {:reply, ref, state}
    end

    def handle_call({:run, func}, _from, state), do: func.(state)

    def run(pid, func) do
      GenServer.call(pid, {:run, func})
    end

    def subscribe(pid, {:repo, _} = arg) do
      GenServer.call(pid, {:subscribe, arg})
    end

    def trigger_disconnect(pid) do
      run(pid, fn state ->
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
      end)
    end
  end

  defmodule CommentPublisher do
    use GenServer

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    def init({client, parent}), do: {:ok, %{client: client, parent: parent}}

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
      response = Req.post!(state.client, graphql: {opts[:query], opts[:variables]})
      comment_id = get_in(response.body, ~w(data repoComment id))

      {:reply, comment_id, state}
    end
  end

  setup do
    url = AbsintheClientTest.Endpoint.url()

    {:ok, %{url: url}}
  end

  test "pushes a subscription to the server and receives a success reply", %{url: url} do
    client = Req.new(base_url: url) |> AbsintheClient.attach()
    pid = start_supervised!({CommentSubscriber, {client, self()}})

    ref = CommentSubscriber.subscribe(pid, {:repo, "ELIXIR"})

    assert_receive {:subscription_reply, ^ref, subscription_id}

    assert subscription_id
  end

  test "forwards a subscription message to the subscribed caller", %{url: url} do
    client = Req.new(method: :post, base_url: url) |> AbsintheClient.attach()
    subscriber_pid = start_supervised!({CommentSubscriber, {client, self()}})

    repo = "ABSINTHE"
    ref = CommentSubscriber.subscribe(subscriber_pid, {:repo, repo})

    publisher_pid = start_supervised!({CommentPublisher, {client, self()}})
    comment_id = CommentPublisher.publish!(publisher_pid, repository: repo, commentary: "hi")

    assert_receive {:subscription_data, ^ref, _, %{"id" => ^comment_id, "commentary" => "hi"}}
  end

  test "messages are not sent for cleared subscriptions", %{url: url, test: test} do
    client = Req.new(base_url: url) |> AbsintheClient.attach()
    publisher_pid = start_supervised!({CommentPublisher, {client, self()}})
    subscriber_pid = start_supervised!({CommentSubscriber, {client, self()}})

    # Subscribes and receives a message on the ABSINTHE repository topic.
    abs_ref = CommentSubscriber.subscribe(subscriber_pid, {:repo, "ABSINTHE"})
    assert_receive {:subscription_reply, ^abs_ref, abs_subscription_id}

    abs_comment_id =
      CommentPublisher.publish!(publisher_pid,
        repository: "ABSINTHE",
        commentary: abs_commentary = "absinthe:#{test}"
      )

    assert_receive {:subscription_data, ^abs_ref, ^abs_subscription_id,
                    %{"id" => ^abs_comment_id, "commentary" => ^abs_commentary}}

    # Unsubscribes from the ABSINTHE repository and subscribes to the PHOENIX repository.
    clear_subscriptions_ref =
      CommentSubscriber.run(subscriber_pid, fn state ->
        AbsintheClient.WebSocket.clear_subscriptions(state.socket, ref = make_ref())
        {:reply, ref, state}
      end)

    assert_receive {:subscription_reply, ^clear_subscriptions_ref, ^abs_subscription_id}

    phx_ref = CommentSubscriber.subscribe(subscriber_pid, {:repo, "PHOENIX"})
    assert_receive {:subscription_reply, ^phx_ref, phx_subscription_id}

    # We expect to *not* receive any more messages from the
    # ABSINTHE repository topic, so we publish its comment
    # first.
    _abs_comment_id =
      CommentPublisher.publish!(publisher_pid,
        repository: "ABSINTHE",
        commentary: _abs_commentary = "absinthe:#{test}"
      )

    # Then, we publish a new comment to the PHOENIX
    # repository and await its reply.
    phx_comment_id =
      CommentPublisher.publish!(publisher_pid,
        repository: "PHOENIX",
        commentary: phx_commentary = "phx:#{test}"
      )

    assert_receive {:subscription_data, ^phx_ref, ^phx_subscription_id,
                    %{"id" => ^phx_comment_id, "commentary" => ^phx_commentary}}

    # After we have received the PHOENIX message above, we
    # ensure that we did not receive any more messages on the
    # ABSINTHE repository topic.
    refute_received {:subscription_data, ^abs_ref, _, _}
  end

  test "rejoining active subscription on reconnect", %{url: url, test: test} do
    client = Req.new(base_url: url) |> AbsintheClient.attach()
    publisher_pid = start_supervised!({CommentPublisher, {client, self()}})
    subscriber_pid = start_supervised!({CommentSubscriber, {client, self()}})

    repo = "PHOENIX"
    text = "#{test}"

    ref = CommentSubscriber.subscribe(subscriber_pid, {:repo, repo})
    assert_receive {:subscription_reply, ^ref, subscription_id}

    comment_id = CommentPublisher.publish!(publisher_pid, repository: repo, commentary: text)

    assert_receive {:subscription_data, ^ref, ^subscription_id,
                    %{"id" => ^comment_id, "commentary" => ^text}}

    :ok = CommentSubscriber.trigger_disconnect(subscriber_pid)

    refute_receive {:subscription_reply, ^ref, _}

    new_text = String.duplicate(text, 2)

    new_comment_id =
      CommentPublisher.publish!(publisher_pid, repository: repo, commentary: new_text)

    assert_receive {:subscription_data, ^ref, _,
                    %{"id" => ^new_comment_id, "commentary" => ^new_text}}
  end

  test "rejoins do not send replies", %{url: url} do
    client = Req.new(base_url: url) |> AbsintheClient.attach()
    subscriber_pid = start_supervised!({CommentSubscriber, {client, self()}})

    ref = CommentSubscriber.subscribe(subscriber_pid, {:repo, "PHOENIX"})
    assert_receive {:subscription_reply, ^ref, _}

    :ok = CommentSubscriber.trigger_disconnect(subscriber_pid)

    refute_receive {:subscription_reply, ^ref, _}
  end
end
