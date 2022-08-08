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
      docs: docs()
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
      {:slipstream, "~> 1.0"},
      {:ex_doc, ">= 0.0.0", only: [:docs], runtime: false}
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
