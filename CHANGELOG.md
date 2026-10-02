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

## v0.1.1 (2024-06-13)

- Support newer req

## v0.1.0 (2022-10-05)

Initial release

