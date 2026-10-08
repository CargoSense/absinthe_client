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

The function always runs inside the socket process, on the first
connection as well as on every reconnect, and never for an operation
sent over the socket. Read the token from a shared
place such as an `Agent`, an ETS table, or a token server, and do not
call into the parent process from it. A raise in the function counts as
a rejected connection and is logged with its stacktrace. `connect/2`
returns `{:ok, pid}` and the socket retries, unless it gives up on the
first attempt, in which case `connect/2` returns `{:error, exception}`.

When the server still rejects the connection, the socket retries with
the same exponential backoff with jitter as the `Req.Steps.retry/1`
step (about 1s, 2s, 4s, 8s, ...), honours a `Retry-After` header on a
429 response, logs a warning per attempt, and gives up after
`:max_rejections` consecutive rejections (default `5`). Set
`:reconnect_delay` to a number of milliseconds or a function of the
attempt count to change the delay for every reconnect. A rejection is
an HTTP 4xx response to the upgrade request, or a failure to build the
request, for example when the `:auth` function raises. The socket
returns an error to every pending operation, sends an
`AbsintheClient.WebSocket.Closed` message to the parent process and to
each subscriber, and stops. Transport errors, such as a refused
connection, 5xx responses, and the transient 408 and 429 responses are
not counted and keep the unbounded backoff from v0.1, with a
`Retry-After` header on a 429 or 503 response setting the delay.

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
     The socket sends it whenever it stops on its own, including after a
     crash. A `nil` ref is the notification to the parent; any other ref
     names a subscription that is gone:

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
     operation is pending, `Req.request/2` and
     `AbsintheClient.WebSocket.await_reply/2` return
     `{:error, %AbsintheClient.WebSocket.Closed{}}`, the same struct the
     socket sends as a message, and `Req.request!/2` and
     `AbsintheClient.WebSocket.await_reply!/2` raise it. Req does not
     retry it. A push to a socket that has already stopped gets a
     `Closed` with the reason `:noproc`. When the server does not reply
     in time the error is `%AbsintheClient.WebSocket.Timeout{}`. Code
     that treated a timeout as "not authorized" should match on `Closed`:

         case Req.request(req, web_socket: ws, graphql: doc) do
           {:ok, response} ->
             response.body

           {:error, %AbsintheClient.WebSocket.Closed{reason: {:rejected, %{status: 403}}}} ->
             # Refresh the credentials and call connect/2 again.

           {:error, %AbsintheClient.WebSocket.Timeout{}} ->
             # The server is slow.
         end

     The `:reason` of a `Closed` is one of `{:rejected, %Req.Response{}}`,
     `{:request_failed, exception}`, `{:disconnected, reason}`,
     `:noproc`, `:shutdown`, or `{:crashed, reason}`. Refer to
     `AbsintheClient.WebSocket.Closed` for their meaning.

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
    responses other than 408 and 429, or request build failures) and send
    `AbsintheClient.WebSocket.Closed` instead of retrying forever.
  * Pending operations receive `{:error, %AbsintheClient.WebSocket.Closed{}}`
    when the socket stops instead of timing out, from `Req.request/2` and
    `AbsintheClient.WebSocket.await_reply/2` alike, and
    `AbsintheClient.WebSocket.await_reply!/2` raises it.
  * `Req.request/2` and `AbsintheClient.WebSocket.await_reply/2` return
    `{:error, %AbsintheClient.WebSocket.Timeout{}}` when the server does
    not reply in time, and `AbsintheClient.WebSocket.await_reply!/2`
    raises it instead of a `RuntimeError`.
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
  * Adds the `:max_rejections` and `:reconnect_delay` options.
  * Adds the `:reconnect` option. `reconnect: false` stops the socket on
    the first disconnect, the same as `retry: false` does for a request,
    and a function decides per disconnect reason.
  * Adds `AbsintheClient.WebSocket.Closed`.
  * `AbsintheClient.WebSocket.await_reply/2` returns
    `{:error, %AbsintheClient.WebSocket.Closed{}}` as soon as the socket
    exits instead of waiting for the timeout.
  * Adds `AbsintheClient.WebSocket.Timeout`.
  * Registers sockets in a `Registry` instead of creating an atom per
    connection.
  * Sends `AbsintheClient.WebSocket.Closed` from `terminate/2`, so a
    crash in the socket notifies the parent and the subscribers too.

## v0.2.0 (2026-10-09)

- Require Req v0.7 and Elixir v1.15 or later
- Use module adapters for WebSocket requests, as Req v0.7 deprecates function adapters
- Support all `transport_opts` in `connect_options` for WebSocket connections (#20)

## v0.1.1 (2024-06-13)

- Support newer req

## v0.1.0 (2022-10-05)

Initial release

