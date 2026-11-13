import Config

if config_env() == :prod do
  control_secret =
    System.get_env("EDGE_CONTROL_SECRET") ||
      raise "environment variable EDGE_CONTROL_SECRET is missing"

  config :edge_proxy,
    control_secret: control_secret
end
