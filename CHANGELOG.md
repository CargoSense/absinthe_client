# CHANGELOG

## v0.2.0-dev

AbsintheClient v0.2 requires Elixir v1.15+ and Req v0.7+.

### WebSocket credential refresh

The socket now runs the request steps again before every connection
attempt. Pass a zero-arity function to `:auth` or `:connect_params` and
the socket calls it each time it connects:

    req =
      Req.new(
        base_url: "https://example.com",
        auth: fn -> {:bearer, MyApp.Token.current!()} end
      )
      |> AbsintheClient.attach()

    {:ok, ws} = AbsintheClient.WebSocket.connect(req)

The function runs inside the socket process. Read the token from a
shared place such as an `Agent`, an ETS table, or a token server.

When the server still rejects the connection, the socket retries with
the same exponential backoff with jitter as the `Req.Steps.retry/1`
step (about 1s, 2s, 4s, 8s, ...), honours a `Retry-After` header on a
429 response, logs a warning per attempt, and gives up after
`:max_rejections` consecutive rejections (default `5`). A rejection is
an HTTP 4xx response to the upgrade request, or a failure to build the
request, for example when the `:auth` function raises. The socket
returns an error to every pending operation, sends an
`AbsintheClient.WebSocket.Closed` message to the parent process and to
each subscriber, and stops. Transport errors, such as a refused
connection, and 5xx responses are not counted and keep the unbounded
backoff from v0.1.

### Socket identity

Sockets are now registered in a `Registry` under the parent process,
the URL, and the transport options. Credentials are not part of the key,
so a second `AbsintheClient.WebSocket.connect/2` call from the same
process with a new token re-uses the running socket and hands it the new
request for its next reconnect. `connect/1,2` return the socket `pid()`
instead of a generated atom.

### Upgrading from v0.1.x

  1. Update your dependency:

         {:absinthe_client, "~> 0.2.0"}

     AbsintheClient v0.2 depends on `{:req, "~> 0.7"}`. If your app pins
     an older Req, update it at the same time.

  2. `AbsintheClient.WebSocket.connect/1,2` and `connect!/1,2` return a
     `pid()`. Remove any name lookups and keep the pid in your process
     state:

         # before
         ws |> GenServer.whereis() |> Process.alive?()

         # after
         Process.alive?(ws)

     The `:web_socket` request option accepts the pid as before. Code that
     pattern matched on the `AbsintheClient.SocketSupervisor.Socket_*`
     atom names must change, as those names no longer exist.

  3. Handle `%AbsintheClient.WebSocket.Closed{}` in the process that
     called `connect/2` and in every process that created a subscription.
     A `nil` ref is the notification to the parent; any other ref names a
     subscription that is gone:

         def handle_info(%AbsintheClient.WebSocket.Closed{ref: nil, reason: reason}, state) do
           # The socket stopped. Fix the credentials and call connect/2 again.
           {:noreply, state}
         end

         def handle_info(%AbsintheClient.WebSocket.Closed{ref: ref}, state) do
           # The subscription with this ref is gone.
           {:noreply, state}
         end

     In v0.1 a socket with rejected credentials retried forever and sent
     no message. To keep retrying for longer, raise `:max_rejections` on
     `AbsintheClient.attach/2` or `connect/2`.

  4. Expect errors instead of timeouts. When the socket stops while an
     operation is pending, `Req.request/2` returns
     `{:error, %AbsintheClient.WebSocket.Error{reason: {:closed, reason}}}`
     with the disconnect reason, and `Req.request!/2` raises it. Req does
     not retry this error. `AbsintheClient.WebSocket.await_reply/2`
     returns `{:error, {:closed, reason}}` with the same reason, and
     `AbsintheClient.WebSocket.await_reply!/2` raises
     `AbsintheClient.WebSocket.Error`. Code that treated a timeout as
     "not authorized" should match on the error instead. A push to a socket that has already
     stopped returns `{:error, %AbsintheClient.WebSocket.Error{}}` from
     `Req.request/2` and `{:error, {:closed, reason}}` from
     `AbsintheClient.WebSocket.await_reply/2`.

  5. Replace static credentials with a function where tokens can expire:

         # before
         Req.new(base_url: url, auth: {:bearer, token})

         # after
         Req.new(base_url: url, auth: fn -> {:bearer, MyApp.Token.current!()} end)

     Static tuples and maps still work. They are sent on every reconnect
     but never refreshed.

  6. If you start `AbsintheClient.WebSocket.AbsintheWs` directly, for
     example in tests, switch to the keyword form:

         # before
         start_supervised!({AbsintheWs, {self(), uri: uri}})

         # after
         start_supervised!({AbsintheWs, parent: self(), config: [uri: uri]})

  7. If one process opened two sockets to the same URL with different
     credentials, it now gets one socket that uses the most recent
     request. Open the sockets from separate parent processes to keep
     them apart.

### Potential breaking changes

  * `AbsintheClient.WebSocket.connect/1,2` return a `pid()` instead of a
    registered name.
  * Sockets stop after `:max_rejections` consecutive rejections (HTTP 4xx
    responses or request build failures) and send
    `AbsintheClient.WebSocket.Closed` instead of retrying forever.
  * Pending operations receive an error when the socket stops instead of
    timing out. `Req.request/2` returns an
    `AbsintheClient.WebSocket.Error` with the disconnect reason, and
    `AbsintheClient.WebSocket.await_reply/2` returns
    `{:error, {:closed, reason}}`.
  * `Req.request/2` returns `{:error, %AbsintheClient.WebSocket.Error{}}`
    when the server does not reply in time or the socket exits first.
    `AbsintheClient.WebSocket.await_reply!/2` raises the same exception
    instead of a `RuntimeError`.
  * A reply that arrives after `AbsintheClient.WebSocket.await_reply/2`
    timed out is discarded instead of delivered to the caller's mailbox.
  * `AbsintheClient.WebSocket.AbsintheWs.start_link/1` takes a keyword list.
  * Elixir v1.15 or later is required.
  * Req v0.7 or later is required.

### Enhancements

  * Re-runs the request steps before every WebSocket connection attempt so
    `auth: fn -> ... end` and `connect_params: fn -> ... end` refresh
    expired tokens.
  * Re-uses the running socket when the same parent connects again with
    new credentials, and adopt the new request for the next reconnect.
  * Adds the `:max_rejections` option.
  * Adds `AbsintheClient.WebSocket.Closed`.
  * `AbsintheClient.WebSocket.await_reply/2` returns
    `{:error, {:closed, reason}}` as soon as the socket exits instead of
    waiting for the timeout.
  * Adds `AbsintheClient.WebSocket.Error`.
  * Registers sockets in a `Registry` instead of creating an atom per
    connection.
  * Restarts the socket supervisor together with the `Registry` so a
    `Registry` crash cannot leave unregistered sockets behind.

## v0.2.0 (2026-10-09)

- Require Req v0.7 and Elixir v1.15 or later
- Use module adapters for WebSocket requests, as Req v0.7 deprecates function adapters
- Support all `transport_opts` in `connect_options` for WebSocket connections (#20)

## v0.1.1 (2024-06-13)

- Support newer req

## v0.1.0 (2022-10-05)

Initial release

