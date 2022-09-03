defmodule AbsintheClient.Integration.SubscriptionsTest do
  use ExUnit.Case

  defmodule CommentSubscriber do
    use GenServer

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    def subscribe(pid, {:repo, _} = arg) do
      GenServer.call(pid, {:subscribe, arg})
    end

    def trigger_disconnect(pid) do
      GenServer.call(pid, :trigger_disconnect)
    end

    def trigger_clear_subscriptions(pid) do
      GenServer.call(pid, :trigger_clear_subscriptions)
    end

    ## Private

    def init({client, parent}) do
      socket_name = AbsintheClient.Request.start_socket(client)

      {
        :ok,
        %{parent: parent, client: client, socket: socket_name, subscription_id_to_ref: %{}}
      }
    end

    def handle_info(%AbsintheClient.WebSocket.Reply{ref: ref, result: result}, state) do
      {:ok, %{"subscriptionId" => subscription_id}} = result

      send(state.parent, {:subscription_reply, ref, subscription_id})

      new_subs = Map.put(state.subscription_id_to_ref, subscription_id, ref)

      {:noreply, %{state | subscription_id_to_ref: new_subs}}
    end

    def handle_info(%AbsintheClient.Subscription.Data{id: subscription_id} = data, state) do
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
      response =
        AbsintheClient.subscribe!(
          state.client,
          {"""
           subscription RepoCommentSubscription($repository: Repository!){
             repoCommentSubscribe(repository: $repository){
               id
               commentary
             }
           }
           """, %{"repository" => name}}
        )

      %{
        body: %{"data" => %{"subscriptionId" => subscription_id}},
        private: %{operation: operation}
      } = response

      send(state.parent, {:subscription_reply, operation.ref, subscription_id})

      new_subs = Map.put(state.subscription_id_to_ref, subscription_id, operation.ref)

      {:reply, {:ok, operation.ref}, %{state | subscription_id_to_ref: new_subs}}
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

    def handle_call(:trigger_clear_subscriptions, _from, state) do
      AbsintheClient.WebSocket.clear_subscriptions(state.socket, ref = make_ref())
      {:reply, ref, state}
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
      response = AbsintheClient.mutate!(state.client, {opts[:query], opts[:variables]})
      comment_id = get_in(response.body, ~w(data repoComment id))

      {:reply, comment_id, state}
    end
  end

  setup do
    http_url = AbsintheClientTest.Endpoint.graphql_url()
    socket_url = AbsintheClientTest.Endpoint.subscription_url()

    {:ok, %{http_url: http_url, socket_url: socket_url}}
  end

  test "pushes a subscription to the server and receives a success reply",
       %{socket_url: socket_url} do
    client = Req.new(method: :post, url: socket_url) |> AbsintheClient.Request.attach()
    pid = start_supervised!({CommentSubscriber, {client, self()}})

    {:ok, ref} = CommentSubscriber.subscribe(pid, {:repo, "ELIXIR"})

    assert_receive {:subscription_reply, ^ref, subscription_id}

    assert subscription_id
  end

  test "forwards a subscription message to the subscribed caller",
       %{http_url: http_url, socket_url: socket_url} do
    ws_client = Req.new(method: :post, url: socket_url) |> AbsintheClient.Request.attach()
    subscriber_pid = start_supervised!({CommentSubscriber, {ws_client, self()}})

    repo = "ABSINTHE"
    {:ok, ref} = CommentSubscriber.subscribe(subscriber_pid, {:repo, repo})

    http_client = Req.new(method: :post, url: http_url) |> AbsintheClient.Request.attach()
    publisher_pid = start_supervised!({CommentPublisher, {http_client, self()}})
    comment_id = CommentPublisher.publish!(publisher_pid, repository: repo, commentary: "hi")

    assert_receive {:subscription_data, ^ref, _, %{"id" => ^comment_id, "commentary" => "hi"}}
  end

  test "messages are not sent for cleared subscriptions",
       %{http_url: http_url, socket_url: socket_url, test: test} do
    http_client = Req.new(method: :post, url: http_url) |> AbsintheClient.Request.attach()
    publisher_pid = start_supervised!({CommentPublisher, {http_client, self()}})
    ws_client = Req.new(method: :post, url: socket_url) |> AbsintheClient.Request.attach()
    subscriber_pid = start_supervised!({CommentSubscriber, {ws_client, self()}})

    # Subscribes and receives a message on the ABSINTHE repository topic.
    {:ok, abs_ref} = CommentSubscriber.subscribe(subscriber_pid, {:repo, "ABSINTHE"})
    assert_receive {:subscription_reply, ^abs_ref, abs_subscription_id}

    abs_comment_id =
      CommentPublisher.publish!(publisher_pid,
        repository: "ABSINTHE",
        commentary: abs_commentary = "absinthe:#{test}"
      )

    assert_receive {:subscription_data, ^abs_ref, ^abs_subscription_id,
                    %{"id" => ^abs_comment_id, "commentary" => ^abs_commentary}}

    # Unsubscribes from the ABSINTHE repository and subscribes to the PHOENIX repository.
    clear_subscriptions_ref = CommentSubscriber.trigger_clear_subscriptions(subscriber_pid)
    assert_receive {:subscription_reply, ^clear_subscriptions_ref, ^abs_subscription_id}

    {:ok, phx_ref} = CommentSubscriber.subscribe(subscriber_pid, {:repo, "PHOENIX"})
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

  test "rejoining active subscription on reconnect",
       %{http_url: http_url, socket_url: socket_url, test: test} do
    http_client = Req.new(method: :post, url: http_url) |> AbsintheClient.Request.attach()
    publisher_pid = start_supervised!({CommentPublisher, {http_client, self()}})

    ws_client = Req.new(method: :post, url: socket_url) |> AbsintheClient.Request.attach()
    subscriber_pid = start_supervised!({CommentSubscriber, {ws_client, self()}})

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
