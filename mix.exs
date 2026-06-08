defmodule EdgeProxy.MixProject do
  use Mix.Project

  def project do
    [
      app: :edge_proxy,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      compilers: [:phoenix] ++ Mix.compilers(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      mod: {EdgeProxy.Application, []},
      extra_applications: [
        :logger,
        :crypto,
        :telemetry
      ]
    ]
  end

  # ------------------------------------------------------------
  # Compilation paths
  # ------------------------------------------------------------

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # ------------------------------------------------------------
  # Dependencies
  # ------------------------------------------------------------

  defp deps do
    [
      # HTTP proxy transport
      {:mint, "~> 1.6"},

      # WebSocket support for LiveView proxying
      {:castore, "~> 1.0"},

      # Plug integration (used in Phoenix endpoints)
      {:plug, "~> 1.15"},

      # Optional telemetry hooks
      {:telemetry, "~> 1.2"},

      # Optional JSON handling for control plane
      {:jason, "~> 1.4"},

      {:igniter, "~> 0.7"},

      # Only needed if you later expand to Phoenix Channels control plane
      # {:phoenix, "~> 1.7", only: [:dev, :test]}
    ]
  end
end
