defmodule EdgeProxy.Application do
  @moduledoc """
  OTP Application entrypoint and supervision tree for EdgeProxy.
  """

  use Application

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
      ] ++ maybe_mesh_bridge()


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
end
