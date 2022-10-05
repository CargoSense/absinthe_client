defmodule Absinthe.Socket.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/CargoSense/absinthe_socket"

  def project do
    [
      app: :absinthe_client,
      version: @version,
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      aliases: [
        "test.all": ["test --include integration"]
      ],
      preferred_cli_env: [
        "test.all": :test,
        docs: :docs,
        "hex.publish": :docs
      ],
      test_coverage: [summary: [threshold: 80]]
    ]
  end

  def application do
    [
      mod: {AbsintheClient.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      description: "AbsintheClient is a GraphQL client designed for Elixir Absinthe.",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp deps do
    [
      {:castore, ">= 0.0.0"},
      {:req, "~> 0.3.0"},
      {:slipstream, "~> 1.0"},
      # Dev/Test dependencies
      {:ex_doc, ">= 0.0.0", only: [:docs], runtime: false},
      {:plug_cowboy, "~> 2.0", only: [:dev, :test]},
      {:absinthe_phoenix, "~> 2.0.0", only: [:dev, :docs, :test]}
    ]
  end

  defp docs do
    [
      source_url: @source_url,
      source_ref: "v#{@version}",
      deps: [],
      language: "en",
      formatters: ["html"],
      main: "readme",
      groups_for_functions: [
        "Request steps": &(&1[:step] == :request),
        "Response steps": &(&1[:step] == :response),
        "Error steps": &(&1[:step] == :error)
      ],
      groups_for_modules: [
        # Ungrouped modules
        # AbsintheClient
        # AbsintheClient.WebSocket

        Structures: [
          AbsintheClient.Subscription,
          AbsintheClient.WebSocket.Message,
          AbsintheClient.WebSocket.Reply
        ]
      ],
      extras: [
        "README.md",
        "CHANGELOG.md"
      ]
    ]
  end
end
