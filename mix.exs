defmodule EdgeProxy.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com"

  def project do
    [
      app: :edge_proxy,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "EdgeProxy",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
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
      {:telemetry, "~> 1.3"},

      # Optional Phoenix / LiveView, Igniter & Service Mesh integrations
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:igniter, "~> 0.5", only: [:dev, :test], optional: true},
      {:ex_service_mesh_router, "~> 0.1", optional: true},

      # Documentation & Testing
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:bandit, "~> 1.5", only: :test}
    ]
  end

  defp description do
    "A BEAM-native, tenant-aware reverse proxy, weighted load balancer, and edge gateway for Phoenix umbrella applications."
  end

  defp package do
    [
      name: "edge_proxy",
      licenses: ["MIT"],
      maintainers: ["Jason Clark"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(
        lib
        mix.exs
        README.md
        SETUP.md
        USAGE.md
        CHANGELOG.md
        LICENSE
      )
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "SETUP.md",
        "USAGE.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_modules: [
        "Core Gateway": [
          EdgeProxy,
          EdgeProxy.Application,
          EdgeProxy.Plug.Router,
          EdgeProxy.Config.Loader,
          EdgeProxy.State
        ],
        "Routing & Load Balancing": [
          EdgeProxy.Routing.Runtime,
          EdgeProxy.Routing.PathRouter,
          EdgeProxy.Routing.Balancer
        ],
        "HTTP & WebSocket Proxy": [
          EdgeProxy.HTTP.Forwarder,
          EdgeProxy.LiveView.Session,
          EdgeProxy.LiveView.SessionSupervisor
        ],
        "Resilience & Telemetry": [
          EdgeProxy.RateLimiter,
          EdgeProxy.HealthChecker,
          EdgeProxy.Telemetry,
          EdgeProxy.Metrics.Plug
        ],
        "Control Plane": [
          EdgeProxy.Control.Plug,
          EdgeProxy.Control.Socket,
          EdgeProxy.Control.Security,
          EdgeProxy.Control.Client
        ],
        "Downstream App Contract": [
          EdgeProxy.EdgeContract,
          EdgeContract.Plug,
          EdgeContract.LiveView,
          EdgeContract.TenantEnforcer
        ],
        "Integrations & Mix Tasks": [
          EdgeProxy.MeshBridge,
          EdgeProxy.Igniter.Extension,
          Mix.Tasks.EdgeProxy.Install,
          Mix.Tasks.EdgeProxy.Control
        ]
      ]
    ]
  end
end
