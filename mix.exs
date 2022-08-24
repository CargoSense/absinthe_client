defmodule Absinthe.Socket.MixProject do
  use Mix.Project

  def project do
    [
      app: :absinthe_socket,
      version: "0.1.0",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: "https://github.com/CargoSense/absinthe_socket",
      name: "Absinthe.Socket",
      docs: docs(),
      test_coverage: [summary: [threshold: 80]]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
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
      deps: [],
      language: "en",
      formatters: ["html"],
      main: Absinthe.Socket
    ]
  end
end
