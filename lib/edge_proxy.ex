defmodule EdgeProxy do
  @moduledoc """
  EdgeProxy core entrypoint and Plug.
  """

  @behaviour Plug
  require Logger

  alias EdgeProxy.Routing.Runtime
  alias EdgeProxy.HTTP.Forwarder
  alias EdgeProxy.LiveView.Session

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    case Runtime.resolve(conn) do
      {:ok, route} ->
        conn = inject_contract_headers(conn, route)

        if websocket_upgrade?(conn) do
          Session.upgrade(conn, route, opts)
        else
          Forwarder.forward(conn, route)
        end

      {:error, :circuit_open} ->
        Plug.Conn.send_resp(conn, 503, "Service Unavailable (Circuit Open)")

      {:error, :no_route} ->
        Plug.Conn.send_resp(conn, 404, "No Route Found")

      {:error, reason} ->
        Logger.warning("EdgeProxy routing failed: #{inspect(reason)}")
        Plug.Conn.send_resp(conn, 502, "EdgeProxy routing error: #{inspect(reason)}")
    end
  end

  def update_routes(new_routes), do: Runtime.update(new_routes)
  def set_circuit_breaker(tenant, state), do: Runtime.set_circuit_breaker(tenant, state)

  defp websocket_upgrade?(conn) do
    conn
    |> Plug.Conn.get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end

  defp inject_contract_headers(conn, route) do
    request_id =
      case Plug.Conn.get_req_header(conn, "x-request-id") do
        [id | _] -> id
        [] -> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      end

    conn
    |> put_if_present("x-edge-tenant", route.tenant)
    |> Plug.Conn.put_req_header("x-edge-domain", route.host)
    |> Plug.Conn.put_req_header("x-request-id", request_id)
  end

    @impl true
  def call(conn, opts) do
    with {:ok, route} <- Runtime.resolve(conn),
         :ok <- EdgeProxy.RateLimiter.check(route.tenant) do
      conn = inject_contract_headers(conn, route)

      if websocket_upgrade?(conn) do
        Session.upgrade(conn, route, opts)
      else
        Forwarder.forward(conn, route)
      end
    else
      {:error, :rate_limited, retry_after} ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(retry_after))
        |> Plug.Conn.send_resp(429, "Too Many Requests")

      {:error, :circuit_open} ->
        Plug.Conn.send_resp(conn, 503, "Service Unavailable (Circuit Open)")

      {:error, :no_route} ->
        Plug.Conn.send_resp(conn, 404, "No Route Found")

      {:error, reason} ->
        Logger.warning("EdgeProxy routing failed: #{inspect(reason)}")
        Plug.Conn.send_resp(conn, 502, "EdgeProxy routing error: #{inspect(reason)}")
    end
  end

  @impl true
def call(conn, opts) do
  start_time = System.monotonic_time()

  with {:ok, route} <- Runtime.resolve(conn),
       :ok <- EdgeProxy.RateLimiter.check(route.tenant) do
    conn = inject_contract_headers(conn, route)

    result_conn =
      if websocket_upgrade?(conn) do
        Session.upgrade(conn, route, opts)
      else
        Forwarder.forward(conn, route)
      end

    EdgeProxy.Telemetry.emit_request(
      System.monotonic_time() - start_time,
      route.tenant,
      conn.method,
      result_conn.status || 101
    )

    result_conn
  else
    {:error, :rate_limited, retry_after} ->
      EdgeProxy.Telemetry.emit_rate_limited(first_tenant(conn))

      conn
      |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(retry_after))
      |> Plug.Conn.send_resp(429, "Too Many Requests")

    {:error, :circuit_open} ->
      EdgeProxy.Telemetry.emit_request(System.monotonic_time() - start_time, first_tenant(conn), conn.method, 503)
      Plug.Conn.send_resp(conn, 503, "Service Unavailable (Circuit Open)")

    {:error, :no_route} ->
      EdgeProxy.Telemetry.emit_request(System.monotonic_time() - start_time, nil, conn.method, 404)
      Plug.Conn.send_resp(conn, 404, "No Route Found")

    {:error, reason} ->
      Logger.warning("EdgeProxy routing failed: #{inspect(reason)}")
      EdgeProxy.Telemetry.emit_request(System.monotonic_time() - start_time, nil, conn.method, 502)
      Plug.Conn.send_resp(conn, 502, "EdgeProxy routing error: #{inspect(reason)}")
  end
end

defp first_tenant(conn) do
  Plug.Conn.get_req_header(conn, "x-edge-tenant") |> List.first()
end



  defp put_if_present(conn, _key, nil), do: conn
  defp put_if_present(conn, key, val), do: Plug.Conn.put_req_header(conn, key, to_string(val))
end
