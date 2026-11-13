defmodule EdgeProxy.TelemetryTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias EdgeProxy.Metrics.Plug, as: MetricsPlug
  alias EdgeProxy.Routing.Runtime
  alias EdgeProxy.Telemetry

  setup do
    Telemetry.reset()

    on_exit(fn ->
      Telemetry.reset()
      Application.delete_env(:edge_proxy, :metrics_token)
      Runtime.set_circuit_breaker("metrics_tenant", :closed)
      Runtime.update([])
    end)

    :ok
  end

  test "records and scrapes Prometheus metrics for requests, rate limits, circuits, and upstreams" do
    Telemetry.emit_request(15_000_000, "metrics_tenant", "GET", 200)
    Telemetry.emit_rate_limited("metrics_tenant")
    Runtime.set_circuit_breaker("metrics_tenant", :open)
    :sys.get_state(Runtime)
    Telemetry.emit_upstream_health({:http, "127.0.0.1", 4001}, true)

    conn = conn(:get, "/metrics") |> MetricsPlug.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/plain; version=0.0.4; charset=utf-8"]

    body = conn.resp_body
    assert body =~ ~s(edge_proxy_requests_total{tenant="metrics_tenant",method="GET",status="200"} 1)
    assert body =~ ~s(edge_proxy_request_duration_seconds_count{tenant="metrics_tenant"} 1)
    assert body =~ ~s(edge_proxy_rate_limited_total{tenant="metrics_tenant"} 1)
    assert body =~ ~s(edge_proxy_circuit_breaker_state{tenant="metrics_tenant"} 1)
    assert body =~ ~s(edge_proxy_upstream_healthy{upstream="http://127.0.0.1:4001"} 1)
  end

  test "enforces optional Bearer token protection on /metrics" do
    Application.put_env(:edge_proxy, :metrics_token, "prom_secret")

    unauth = conn(:get, "/metrics") |> MetricsPlug.call([])
    assert unauth.status == 401

    auth =
      conn(:get, "/metrics")
      |> put_req_header("authorization", "Bearer prom_secret")
      |> MetricsPlug.call([])

    assert auth.status == 200
  end
end
