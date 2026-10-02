# CHANGELOG

## Unreleased

### Breaking changes

- `AbsintheClient.WebSocket.connect/1,2` now return the socket `pid()` instead of
  a registered name. Sockets are tracked in a `Registry` keyed by parent process,
  URL, and transport options, so credentials no longer affect socket identity and
  no atoms are created per connection.
- `AbsintheClient.WebSocket.AbsintheWs.start_link/1` takes a keyword list.

## v0.1.1 (2024-06-13)

- Support newer req

## v0.1.0 (2022-10-05)

Initial release

