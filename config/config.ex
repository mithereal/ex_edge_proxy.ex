import Config

config :edge_proxy,
  control_secret: "control_secret",
  allowed_control_tenants: :all,
  enable_mesh_bridge: :auto,
  rate_limit: [
    enabled: true,
    max_requests: 120,
    window_seconds: 60,
    tenant_overrides: %{"enterprise_tenant" => 1_000}
  ],
  health_check: [
    enabled: true,
    interval_ms: 5_000,
    timeout_ms: 2_000,
    path: "/health",
    failure_threshold: 3,
    recovery_threshold: 2
  ]


import_config "#{config_env()}.exs"
