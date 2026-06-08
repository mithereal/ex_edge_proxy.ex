defmodule EdgeProxy do
  @moduledoc """
  EdgeProxy core entrypoint.

  Responsibilities:
  - resolve tenant/domain from request
  - route HTTP traffic to upstream Phoenix apps
  - handle WebSocket / LiveView upgrades
  - enforce circuit breaker checks
  - inject EdgeContract headers

  This module does NOT contain business logic.
  It only routes and shapes traffic.
  """

  require Logger

  alias EdgeProxy.Routing.Runtime
  alias EdgeProxy.Proxy.HTTP
  alias EdgeProxy.Proxy.WebSocket

  # ------------------------------------------------------------
  # HTTP ENTRYPOINT
  # ------------------------------------------------------------

  def call(conn, opts) do
    case Runtime.resolve(conn) do
      {:ok, route} ->
        HTTP.forward(conn, route, opts)

      {:error, reason} ->
        Logger.warning("EdgeProxy routing failed: #{inspect(reason)}")
        send_error(conn, reason)
    end
  end

  # ------------------------------------------------------------
  # WEBSOCKET / LIVEVIEW UPGRADE ENTRYPOINT
  # ------------------------------------------------------------

  def upgrade(conn, opts) do
    case Runtime.resolve(conn) do
      {:ok, route} ->
        WebSocket.upgrade(conn, route, opts)

      {:error, reason} ->
        Logger.warning("EdgeProxy WS upgrade failed: #{inspect(reason)}")
        send_error(conn, reason)
    end
  end

  # ------------------------------------------------------------
  # INTERNAL: ERROR RESPONSE
  # ------------------------------------------------------------

  defp send_error(conn, reason) do
    Plug.Conn.send_resp(conn, 502, "EdgeProxy routing error: #{inspect(reason)}")
  end

  # ------------------------------------------------------------
  # CONTROL PLANE HOOK (OPTIONAL)
  # ------------------------------------------------------------

  @doc """
  Runtime update hook used by control plane.

  Allows live updates of routing tables without restart.
  """
  def update_routes(new_routes) do
    Runtime.update(new_routes)
  end

  @doc """
  Circuit breaker toggle per tenant.
  """
  def set_circuit_breaker(tenant, state) do
    Runtime.set_circuit_breaker(tenant, state)
  end
end