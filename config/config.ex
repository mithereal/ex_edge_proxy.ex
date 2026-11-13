import Config

config :edge_proxy,
  control_secret: "control_secret",
  allowed_control_tenants: :all,
    # :auto (enables if :ex_service_mesh_router is loaded) | true | false
  enable_mesh_bridge: :auto

import_config "#{config_env()}.exs"
