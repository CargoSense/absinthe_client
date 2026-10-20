# AbsintheClient

A GraphQL client designed for Elixir [Absinthe][absinthe].

[![Package](https://img.shields.io/hexpm/v/absinthe_client?logo=elixir&style=for-the-badge)](https://hex.pm/packages/absinthe_client)
[![Downloads](https://img.shields.io/hexpm/dt/absinthe_client?logo=elixir&style=for-the-badge)](https://hex.pm/packages/absinthe_client)
[![Build](https://img.shields.io/github/actions/workflow/status/CargoSense/absinthe_client/ci.yml?branch=main&logo=github&style=for-the-badge)](https://github.com/CargoSense/absinthe_client/actions/workflows/ci.yml)

## Features

- Performs `query` and `mutation` operations via JSON POST requests.
- Performs `subscription` operations over WebSockets ([Absinthe Phoenix][absinthe_phoenix]).
- Automatically re-establishes subscriptions on socket disconnect/reconnect.
- Refreshes credentials before every WebSocket connection attempt, and tells
  you when the server keeps rejecting them.
- Supports virtually all [`Req.request/1`][request] options, notably:
  - Bearer authentication (via the [`auth`][req_auth] step).
  - Retries on errors (via the [`retry`][req_retry] step).

## Usage

The fastest way to use AbsintheClient is with [`Mix.install/2`][install] (requires Elixir v1.15+):

```elixir
Mix.install([
  {:absinthe_client, "~> 0.1.0"}
])

Req.new(base_url: "https://rickandmortyapi.com")
|> AbsintheClient.attach()
|> Req.post!(graphql: "query { character(id: 1) { name } }").body
#=> %{"data" => "character" => %{"name" => "Rick Sanchez"}}}
```

If you want to use AbsintheClient in a Mix project, you can add the above
dependency to your list of dependencies in `mix.exs`.

AbsintheClient is intended to be used by building a common client struct with a
`base_url` and re-using it on each operation:

```elixir
base_url = "https://rickandmortyapi.com"
req = Req.new(base_url: base_url) |> AbsintheClient.attach()

Req.post!(req, graphql: "query { character(id: 2) { name } }").body
#=> %{"data" => "character" => %{"name" => "Morty Smith"}}}
```

Refer to [`AbsintheClient`][client] for more information on available options.

### Subscriptions (WebSockets)

AbsintheClient supports WebSocket operations via a custom Req adapter. You must
first start the WebSocket connection, then you make the request with
[`Req.request/2`][request2]:

```elixir
base_url = "https://my-absinthe-server"
req = Req.new(base_url: base_url) |> AbsintheClient.attach()

ws = AbsintheClient.WebSocket.connect!(req, url: "/socket/websocket")

Req.request!(req, web_socket: ws, graphql: "subscription ...").body
#=> %AbsintheClient.Subscription{}
```

Note that although AbsintheClient _can_ use the `:web_socket` option to execute
all GraphQL operation types, in most cases it should continue to use HTTP for
queries and mutations. This is because queries and mutations do not require a
stateful or long-lived connection and depending on the number of concurrent
requests it may be more efficient to avoid blocking the socket for those
operations.

Refer to [`AbsintheClient.attach/2`][attach2] for more information on handling
subscriptions.

### Authentication

AbsintheClient supports Bearer authentication for HTTP and WebSocket operations:

```elixir
base_url = "https://my-absinthe-server"
auth = {:bearer, "token"}
req = Req.new(base_url: base_url, auth: auth) |> AbsintheClient.attach()

# ?Authorization=Bearer+token is sent with the connect request.
ws = AbsintheClient.WebSocket.connect!(req, url: "/socket/websocket")
```

Tokens expire. Pass a zero-arity function to `:auth` (or to
`:connect_params`) and the socket calls it before every connection
attempt, so a reconnect always sends the current token:

```elixir
base_url = "https://my-absinthe-server"
auth = fn -> {:bearer, MyApp.Token.current!()} end
req = Req.new(base_url: base_url, auth: auth) |> AbsintheClient.attach()

ws = AbsintheClient.WebSocket.connect!(req, url: "/socket/websocket")
```

If the server keeps rejecting the connection, the socket retries with
exponential backoff, gives up after `:max_rejections` rejections (default
`5`), and sends an `AbsintheClient.WebSocket.Closed` message to the process
that connected it and to every subscriber. Any operation waiting on the
socket gets the same `Closed` as its error. Refer to
[`AbsintheClient.WebSocket.connect/1`][websocket] for the retry policy and
the `:reconnect` and `:reconnect_delay` options.

If you use your client to authenticate then you can set `:auth` by merging
options:

```elixir
base_url = "https://my-absinthe-server"
req = Req.new(base_url: base_url) |> AbsintheClient.attach()

doc = "mutation { login($input) { token } }"
graphql = {doc, %{user: "root", password: ""}}
token = Req.post!(req, graphql: graphql).body["data"]["login"]["token"]
req = Req.Request.merge_options(req, auth: {:bearer, token})
```

## Why AbsintheClient?

There is another popular GraphQL library for Elixir called [Neuron][neuron]. So,
why choose AbsintheClient? In short, you might use AbsintheClient if you need
Absinthe Phoenix subscription support, if you want to avoid global
configuration, and if you want to declaratively build your requests. For
comparison:

|                    | AbsintheClient                                      | Neuron                                      |
|:-------------------|:----------------------------------------------------|:--------------------------------------------|
| **HTTP**           | [Req][req], [Finch][finch]                          | [HTTPoison][httpoison], [hackney][hackney]  |
| **WebSockets**     | [Slipstream][slipstream], [Mint.WebSocket][mint_ws] | n/a                                         |
| **Configuration**  | `%Req.Request{}`                                    | Application and Process-based               |
| **Request style**  | Declarative, builds a struct                        | Imperative, invokes a function              |

## Acknowledgements

AbsintheClient is built on top of the [Req][req] requests library for HTTP and
the [Slipstream][slipstream] WebSocket library for Phoenix Channels.

## License

MIT license. Copyright (c) 2019 Michael A. Crumm Jr., Ben Wilson

[absinthe_phoenix]: https://hexdocs.pm/absinthe_phoenix
[absinthe]: https://github.com/absinthe-graphql/absinthe
[attach2]: https://hexdocs.pm/absinthe_client/AbsintheClient.html#attach/2-subscriptions
[client]: https://hexdocs.pm/absinthe_client/AbsintheClient.html
[finch]: https://github.com/sneako/finch
[hackney]: https://github.com/benoitc/hackney
[httpoison]: https://github.com/edgurgel/httpoison
[install]: https://hexdocs.pm/mix/Mix.html#install/2
[mint_ws]: https://github.com/elixir-mint/mint_web_socket
[neuron]: https://hexdocs.pm/neuron
[req_auth]: https://hexdocs.pm/req/Req.Steps.html#auth/1
[req_retry]: https://hexdocs.pm/req/Req.Steps.html#retry/1
[req]: https://github.com/wojtekmach/req
[request]: https://hexdocs.pm/req/Req.html#request/1
[request2]: https://hexdocs.pm/req/Req.html#request/2
[slipstream]: https://github.com/NFIBrokerage/slipstream
[subscriptions]: https://hexdocs.pm/absinthe/subscriptions.html
[websocket]: https://hexdocs.pm/absinthe_client/AbsintheClient.WebSocket.html
