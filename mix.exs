defmodule EdgeProxy.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :edge_proxy,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {EdgeProxy.Application, []}
    ]
  end

  defp deps do
    [
      # Core HTTP & WebSocket proxying
      {:plug, "~> 1.16"},
      {:mint, "~> 1.6"},
      {:mint_web_socket, "~> 1.0"},
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"},

      # Optional Phoenix / LiveView & Igniter integrations
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:igniter, "~> 0.5", optional: true},

      # Test server for end-to-end HTTP/WebSocket proxy tests
      {:bandit, "~> 1.5", only: :test}
    ]
  end
end
