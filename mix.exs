defmodule AbsintheClient.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/CargoSense/absinthe_client"

  def project do
    [
      app: :absinthe_client,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      description: "A GraphQL client designed for Elixir Absinthe.",
      package: package(),
      aliases: aliases(),
      deps: deps(),
      name: "AbsintheClient",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      test_coverage: [summary: [threshold: 80]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AbsintheClient.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        docs: :docs,
        "hex.publish": :docs,
        "test.all": :test
      ]
    ]
  end

  defp aliases do
    [
      "test.all": ["test --include integration"]
    ]
  end

  defp deps do
    [
      {:castore, ">= 0.0.0"},
      {:req, "~> 0.7"},
      {:slipstream, "~> 1.0"},
      {:absinthe_phoenix, "~> 2.0.0", only: [:dev, :docs, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:docs], runtime: false},
      {:plug_cowboy, "~> 2.0", only: [:dev, :test]}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md"
      ],
      formatters: ["html"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      deps: [],
      language: "en",
      groups_for_functions: [
        "Request steps": &(&1[:step] == :request),
        "Response steps": &(&1[:step] == :response),
        "Error steps": &(&1[:step] == :error)
      ],
      groups_for_modules: [
        Structures: [
          AbsintheClient.Subscription,
          AbsintheClient.WebSocket.Closed,
          AbsintheClient.WebSocket.Error,
          AbsintheClient.WebSocket.Message,
          AbsintheClient.WebSocket.Reply
        ]
      ]
    ]
  end

  defp package do
    [
      description: "A GraphQL client designed for Elixir Absinthe.",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/releases"
      }
    ]
  end
end
