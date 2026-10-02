# CHANGELOG

## Unreleased

### Breaking changes

- `AbsintheClient.WebSocket.connect/1,2` now return the socket `pid()` instead of
  a registered name. Sockets are tracked in a `Registry` keyed by parent process,
  URL, and transport options, so credentials no longer affect socket identity and
  no atoms are created per connection.
- `AbsintheClient.WebSocket.AbsintheWs.start_link/1` takes a keyword list.

### Enhancements

- Re-run the request steps before every WebSocket connection attempt, so
  `auth: fn -> ... end` and `connect_params: fn -> ... end` refresh expired
  tokens on reconnect (#12).
- Connecting again from the same parent with new credentials re-uses the socket
  and updates the request used for the next reconnect.
- Add `:max_rejections` option. After that many consecutive HTTP 4xx rejections
  the socket replies with an error to pending operations, sends
  `AbsintheClient.WebSocket.Closed` to the parent and subscribers, and stops.

## v0.2.0 (2026-10-09)

- Require Req v0.7 and Elixir v1.15 or later
- Use module adapters for WebSocket requests, as Req v0.7 deprecates function adapters
- Support all `transport_opts` in `connect_options` for WebSocket connections (#20)

## v0.1.1 (2024-06-13)

- Support newer req

## v0.1.0 (2022-10-05)

Initial release

