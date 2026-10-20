# CHANGELOG

## v0.3.0-dev (Unreleased)

AbsintheClient v0.3 requires Elixir v1.15+ and Req v0.7+.

### WebSocket credential refresh

The socket runs the request steps again before every connection
attempt. Pass a zero-arity function to `:auth` or `:connect_params` and
the socket calls it each time it connects:

    req =
      Req.new(
        base_url: "https://example.com",
        auth: fn -> {:bearer, MyApp.Token.current!()} end
      )
      |> AbsintheClient.attach()

    {:ok, ws} = AbsintheClient.WebSocket.connect(req)

The function runs inside the socket process, on the first connection
and on every reconnect, and never for an operation sent over the
socket. Read the token from a shared place such as an `Agent`, an ETS
table, or a token server, and do not call into the parent process from
it. A raise in the function counts as a rejected connection and is
logged with its stacktrace.

### Rejected connections

A rejection is an HTTP 4xx response to the upgrade request other than
408 and 429, or a failure to build the request. The socket retries a
rejection with the same exponential backoff with jitter as the
`Req.Steps.retry/1` step, about 1s, 2s, 4s and 8s, logs a warning per
attempt, and gives up after `:max_rejections` rejections (default `5`)
without a successful connection in between. In v0.1 a socket with
rejected credentials retried forever and sent no message.

Everything else keeps the unbounded reconnect from v0.1: a dropped
connection, a refused or timed-out transport, a 5xx response, and the
transient 408 and 429 responses. A `Retry-After` header on a 429 or 503
response sets the delay.

Two options shape this, named after their Req counterparts.
`reconnect: false` stops the socket on the first disconnect of any
kind, and a function decides per `AbsintheClient.WebSocket.Closed`
reason. `:reconnect_delay`
is a number of milliseconds or a function of the attempt count and
applies to every reconnect.

### Closed and Timeout

`AbsintheClient.WebSocket.Closed` is both a message and an error. The
socket sends it to the parent process with a `nil` ref when it stops,
and to the owner of a subscription or of an in-flight document with
that ref when the operation is gone. `Req.request/2` and
`AbsintheClient.WebSocket.await_reply/2` return it in their error
tuple, and `Req.request!/2` and `AbsintheClient.WebSocket.await_reply!/2`
raise it. After a `Closed` with a `nil` ref the socket is gone and
`connect/2` is the way back. After a `Closed` with a ref only that
operation is gone.

`AbsintheClient.WebSocket.Timeout` is the error when the server does not
reply in time. The socket is still usable, so the operation can be sent
again. The socket cancels the timed-out push: a late reply is discarded
and a subscription it created is unsubscribed at once.

### Socket identity

Sockets are registered in a `Registry` under the parent process, the
URL, and the transport options. Credentials are not part of the key, so
a second `AbsintheClient.WebSocket.connect/2` from the same process with
a new token re-uses the running socket and hands it the new request for
its next reconnect. A second `connect/2` that differs in anything else
returns an error. `connect/1,2` return the socket `pid()` instead of a
generated atom.

### Upgrading from v0.1.x

  1. Update your dependency:

         {:absinthe_client, "~> 0.3.0"}

     AbsintheClient v0.3 depends on `{:req, "~> 0.7"}`. If your app pins
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
     names a subscription, or a document that was in flight when the
     connection dropped, that is gone:

         def handle_info(%AbsintheClient.WebSocket.Closed{ref: nil, reason: reason}, state) do
           # The socket stopped. Fix the credentials and call connect/2 again.
           {:noreply, state}
         end

         def handle_info(%AbsintheClient.WebSocket.Closed{ref: ref}, state) do
           # The subscription with this ref is gone. Push the document again.
           {:noreply, state}
         end

     To keep retrying for longer, raise `:max_rejections` on
     `AbsintheClient.attach/2` or `connect/2`.

  4. Expect errors instead of timeouts. When the socket stops while an
     operation is pending, or the connection drops while a document is
     in flight, `Req.request/2` and
     `AbsintheClient.WebSocket.await_reply/2` return
     `{:error, %AbsintheClient.WebSocket.Closed{}}`, and `Req.request!/2`
     and `AbsintheClient.WebSocket.await_reply!/2` raise it. Req does not
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

  6. If you start the internal socket module, `AbsintheWs`, directly, for
     example in tests, switch to the keyword form:

         # before
         start_supervised!({AbsintheWs, {self(), uri: uri}})

         # after
         start_supervised!({AbsintheWs, parent: self(), config: [uri: uri]})

  7. If one process opened two sockets to the same URL with different
     credentials, it now gets one socket that uses the most recent
     request. A second `connect/2` that differs in anything other than
     the credentials, such as `:max_rejections` or a header, returns
     `{:error, %ArgumentError{}}`. Open the sockets from separate parent
     processes to keep them apart.

  8. `AbsintheClient.WebSocket.push/2` returns an
     `AbsintheClient.WebSocket.Push` instead of a reference, and so does
     the body of an `async: true` response. Pass it to
     `AbsintheClient.WebSocket.await_reply/2`. Its `:ref` field is the
     ref the `AbsintheClient.WebSocket.Reply` carries:

         # before
         ref = AbsintheClient.WebSocket.push(ws, doc)
         AbsintheClient.WebSocket.await_reply(ref)

         # after
         push = AbsintheClient.WebSocket.push(ws, doc)
         AbsintheClient.WebSocket.await_reply(push)

     When `await_reply/2` times out, the socket cancels the push: a late
     reply is discarded, and a subscription it created is unsubscribed
     at once, so a timed-out subscription never delivers data.

### Potential breaking changes

  * `AbsintheClient.WebSocket.connect/1,2` return a `pid()` instead of a
    registered name.
  * Sockets stop after `:max_rejections` rejections (HTTP 4xx responses
    other than 408 and 429, or request build failures) without a
    successful connection in between, and send
    `AbsintheClient.WebSocket.Closed` instead of retrying forever.
  * A second `AbsintheClient.WebSocket.connect/2` from the same process
    to the same URL returns `{:error, %ArgumentError{}}` when anything
    other than the credentials differs.
  * Pending operations receive `{:error, %AbsintheClient.WebSocket.Closed{}}`
    when the socket stops, or when the connection drops while the
    document is in flight, instead of timing out. `Req.request/2` and
    `AbsintheClient.WebSocket.await_reply/2` return it, and
    `AbsintheClient.WebSocket.await_reply!/2` raises it.
  * `Req.request/2` over a WebSocket returns status `200` for a reply
    with GraphQL `"errors"`, as `Absinthe.Plug` does over HTTP, instead
    of `500`. Only a reply that is not a result, such as a bare error
    message, is `500`. Req's `retry` step no longer re-pushes a document
    the server answered with errors.
  * `Req.request/2` and `AbsintheClient.WebSocket.await_reply/2` return
    `{:error, %AbsintheClient.WebSocket.Timeout{}}` when the server does
    not reply in time, and `AbsintheClient.WebSocket.await_reply!/2`
    raises it instead of a `RuntimeError`.
  * `AbsintheClient.WebSocket.push/2` and the body of an `async: true`
    response are an `AbsintheClient.WebSocket.Push` instead of a
    reference, and `AbsintheClient.WebSocket.await_reply/2` takes it.
  * A reply that arrives after `AbsintheClient.WebSocket.await_reply/2`
    timed out is discarded instead of delivered to the caller's mailbox,
    and a subscription it created is unsubscribed.
  * `AbsintheClient.WebSocket.Message` no longer has a `:push_ref` field.
    It was never set.
  * The internal socket module, `AbsintheWs`, takes a keyword list in
    `start_link/1`.
  * Elixir v1.15 or later is required.
  * Req v0.7 or later is required.

### Enhancements

  * Re-runs the request steps before every WebSocket connection attempt,
    inside the socket process, so `auth: fn -> ... end` and
    `connect_params: fn -> ... end` refresh expired tokens.
  * Re-uses the running socket when the same parent connects again with
    new credentials, and adopts the new request for the next reconnect.
  * Retries rejected connections with exponential backoff and jitter,
    honours `Retry-After`, and logs each failed upgrade.
  * Adds the `:max_rejections`, `:reconnect` and `:reconnect_delay`
    options.
  * Adds `AbsintheClient.WebSocket.Closed`, sent when the socket stops,
    including after a crash, and when a subscription or an in-flight
    document is gone, and returned as the error of a pending operation.
  * Adds `AbsintheClient.WebSocket.Timeout`.
  * Adds `AbsintheClient.WebSocket.Push`, and cancels a push when
    `AbsintheClient.WebSocket.await_reply/2` times out, so a late
    subscription reply is unsubscribed instead of delivering data.
  * Fails a document that is in flight when the connection drops at
    once, instead of leaving the caller to wait out the receive timeout.
    Active subscriptions are still re-subscribed on reconnect.
  * Registers sockets in a `Registry` instead of creating an atom per
    connection.
  * Keeps credentials out of the socket state, so they do not appear in
    crash reports.

## v0.2.0 (2026-10-09)

- Require Req v0.7 and Elixir v1.15 or later
- Use module adapters for WebSocket requests, as Req v0.7 deprecates function adapters
- Support all `transport_opts` in `connect_options` for WebSocket connections (#20)

## v0.1.1 (2024-06-13)

- Support newer req

## v0.1.0 (2022-10-05)

Initial release

