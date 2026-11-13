import Config

config :edge_proxy,
  control_secret: "control_secret",
  allowed_control_tenants: :all

import_config "#{config_env()}.exs"
