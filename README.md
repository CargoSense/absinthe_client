# AbsintheClient

[![CI](https://github.com/CargoSense/absinthe_client/actions/workflows/ci.yml/badge.svg)](https://github.com/CargoSense/absinthe_client/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/hex.pm-docs-8e7ce6.svg)](https://hexdocs.pm/absinthe_client)
[![Hex pm](http://img.shields.io/hexpm/v/absinthe_client.svg?style=flat&color=brightgreen)](https://hex.pm/packages/absinthe_client)

A GraphQL client designed for Elixir [Absinthe][absinthe].

## Features

- Performs `query` and `mutation` operations via JSON POST requests.

- Performs `subscription` operations over WebSockets ([Absinthe Phoenix][absinthe_phoenix]).

- Automatically re-establishes subscriptions on socket disconnect/reconnect.

- Supports virtually all [`Req.request/1`][request] options, notably:

  - Bearer authentication (via the [`auth`][req_auth] step).

  - Retries on errors (via the [`retry`][req_retry] step).

## Usage

The fastest way to use AbsintheClient is with [`Mix.install/2`][install] (requires Elixir v1.12+):

```elixir
Mix.install([
  {:absinthe_client, "~> 0.1.0"}
])

Req.new(base_url: "https://rickandmortyapi.com")
|> AbsintheClient.attach()
|> Req.post!(graphql: "query { character(id: 1) { name } }").body
#=> %{"data" => "character" => %{"name" => "Rick Sanchez"}}}
```

If you want to use AbsintheClient in a Mix project, you can add the above dependency to your list of dependencies in `mix.exs`.

AbsintheClient is intended to be used by building a common client
struct with a `base_url` and re-using it on each operation:

```elixir
base_url = "https://rickandmortyapi.com"
req = Req.new(base_url: base_url) |> AbsintheClient.attach()

Req.post!(req, graphql: "query { character(id: 2) { name } }").body
#=> %{"data" => "character" => %{"name" => "Morty Smith"}}}
```

Refer to [`AbsintheClient`][client] for more information on available options.

### Subscriptions (WebSockets)

AbsintheClient supports WebSocket operations via a custom Req adapter.
You must first start the WebSocket connection, then you make the
request with [`Req.request/2`][request2]:

```elixir
base_url = "https://my-absinthe-server"
req = Req.new(base_url: base_url) |> AbsintheClient.attach()

ws = AbsintheClient.WebSocket.connect!(req, url: "/socket/websocket")

Req.request!(req, web_socket: ws, graphql: "subscription ...").body
#=> %AbsintheClient.WebSocket.Subscription{}
```

Note that although AbsintheClient _can_ use the `:web_socket` option
to execute all GraphQL operation types, in most cases it should
continue to use HTTP for queries and mutations. This is because
queries and mutations do not require a stateful or long-lived
connection and depending on the number of concurrent requests it may
be more efficient to avoid blocking the socket for those operations.

Refer to [`AbsintheClient.attach/2`][attach2] for more information on handling subscriptions.

### Authentication

AbsintheClient supports Bearer authentication for HTTP and WebSocket operations:

```elixir
base_url = "https://my-absinthe-server"
auth = {:bearer, "token"}
req = Req.new(base_url: base_url, auth: auth) |> AbsintheClient.attach()

# ?Authentication=Bearer+token will be sent on the connect request.
ws = AbsintheClient.WebSocket.connect(req, url: "/socket/websocket")
```

If you use your client to authenticate then you can set `:auth` by
merging options:

```elixir
base_url = "https://my-absinthe-server"
req = Req.new(base_url: base_url) |> AbsintheClient.attach()

doc = "mutation { login($input) { token } }"
graphql = {doc, %{user: "root", password: ""}}
token = Req.post!(req, graphql: graphql).body["data"]["login"]["token"]
req = Req.Request.merge_options(req, auth: {:bearer, token})
```

## Why AbsintheClient?

There is another popular GraphQL library for Elixir called [Neuron][neuron].
So why choose AbsintheClient? In short, you might use AbsintheClient if you
need Absinthe Phoenix subscription support, if you want to avoid global
configuration, and if you want to declaratively build your requests. For
comparison:

|                    | AbsintheClient                                      | Neuron                                      |
| ------------------ | --------------------------------------------------- | ------------------------------------------- |
| **HTTP**           | [Req][req], [Finch][finch]                          | [HTTPoison][httpoison], [hackney][hackney]  |
| **WebSockets**     | [Slipstream][slipstream], [Mint.WebSocket][mint_ws] | n/a                                         |
| **Configuration**  | `%Req.Request{}`                                    | Application and Process-based               |
| **Request style**  | Declarative, builds a struct                        | Imperative, invokes a function              |


## Acknowledgements

AbsintheClient is built on top of the [Req][req] requests library for HTTP and the [Slipstream][slipstream] WebSocket library for Phoenix Channels.

## License

MIT license. Copyright (c) 2019 Michael A. Crumm Jr., Ben Wilson

[client]: https://hexdocs.pm/absinthe_client/AbsintheClient.html
[websocket]: https://hexdocs.pm/absinthe_client/AbsintheClient.WebSocket.html
[attach2]: https://hexdocs.pm/absinthe_client/AbsintheClient.html#attach/2-subscriptions
[install]: https://hexdocs.pm/mix/Mix.html#install/2
[absinthe]: https://github.com/absinthe-graphql/absinthe
[absinthe_phoenix]: https://hexdocs.pm/absinthe_phoenix
[req]: https://github.com/wojtekmach/req
[request]: https://hexdocs.pm/req/Req.html#request/1
[request2]: https://hexdocs.pm/req/Req.html#request/2
[req_auth]: https://hexdocs.pm/req/Req.Steps.html#auth/1
[req_retry]: https://hexdocs.pm/req/Req.Steps.html#retry/1
[slipstream]: https://github.com/NFIBrokerage/slipstream
[subscriptions]: https://hexdocs.pm/absinthe/subscriptions.html
[neuron]: https://hexdocs.pm/neuron
[finch]: https://github.com/sneako/finch
[mint_ws]: https://github.com/elixir-mint/mint_web_socket
[httpoison]: https://github.com/edgurgel/httpoison
[hackney]: https://github.com/benoitc/hackney
