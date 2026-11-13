defmodule EdgeProxy.Application do
  @moduledoc """
  OTP Application entrypoint and supervision tree for EdgeProxy.
  """

  use Application

  @compile {:no_warn_undefined, [Bandit, Router.Router]}

  @default_backplane_port 4040
  @default_backplane_ip {127, 0, 0, 1}

  @impl true
  def start(_type, _args) do
    children =
      [
        EdgeProxy.Telemetry,
        EdgeProxy.Routing.Runtime,
        EdgeProxy.RateLimiter,
        EdgeProxy.LiveView.SessionSupervisor,
        EdgeProxy.Control.Socket,
        EdgeProxy.HealthChecker
      ] ++ maybe_mesh_bridge() ++ maybe_mesh_backplane()

    opts = [strategy: :one_for_one, name: EdgeProxy.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      EdgeProxy.Config.Loader.load()
      {:ok, pid}
    end
  end

  defp maybe_mesh_bridge do
    case Application.get_env(:edge_proxy, :enable_mesh_bridge, :auto) do
      false ->
        []

      true ->
        if EdgeProxy.MeshBridge.mesh_available?() do
          [EdgeProxy.MeshBridge]
        else
          raise "config :edge_proxy, enable_mesh_bridge: true requires :ex_service_mesh_router in deps"
        end

      :auto ->
        if EdgeProxy.MeshBridge.mesh_available?(), do: [EdgeProxy.MeshBridge], else: []
    end
  end

  defp maybe_mesh_backplane do
    case Application.get_env(:edge_proxy, :enable_mesh_backplane, :auto) do
      false ->
        []

      true ->
        if backplane_available?() do
          [backplane_child_spec()]
        else
          raise "config :edge_proxy, enable_mesh_backplane: true requires :ex_service_mesh_router and :bandit in deps"
        end

      :auto ->
        # Avoid binding port 4040 automatically during :test unless explicitly enabled
        if Mix.env() != :test and backplane_available?() do
          [backplane_child_spec()]
        else
          []
        end
    end
  end

  defp backplane_available? do
    EdgeProxy.MeshBridge.mesh_available?() and
      Code.ensure_loaded?(Router.Router) and
      Code.ensure_loaded?(Bandit)
  end

  defp backplane_child_spec do
    port = Application.get_env(:edge_proxy, :mesh_backplane_port, @default_backplane_port)
    ip = Application.get_env(:edge_proxy, :mesh_backplane_ip, @default_backplane_ip)

    Supervisor.child_spec(
      {Bandit, plug: Router.Router, port: port, ip: ip},
      id: :edge_proxy_mesh_backplane
    )
  end
end
