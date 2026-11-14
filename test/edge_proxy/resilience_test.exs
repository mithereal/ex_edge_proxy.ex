defmodule EdgeProxy.ResilienceTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias EdgeProxy.{HealthChecker, RateLimiter}
  alias EdgeProxy.Routing.Runtime

  defmodule FlakyUpstream do
    use Agent
    import Plug.Conn

    def start_link(_), do: Agent.start_link(fn -> 200 end, name: __MODULE__)
    def set_status(code), do: Agent.update(__MODULE__, fn _ -> code end)
    def get_status, do: Agent.get(__MODULE__, & &1)

    def init(opts), do: opts

    def call(%{request_path: "/health"} = conn, _opts) do
      send_resp(conn, get_status(), "health")
    end

    def call(conn, _opts) do
      send_resp(conn, 200, "ok")
    end
  end

  setup do
    RateLimiter.reset()

    Application.put_env(:edge_proxy, :rate_limit,
      enabled: true,
      max_requests: 2,
      window_seconds: 60,
      tenant_overrides: %{"vip_tenant" => 5}
    )

    on_exit(fn ->
      RateLimiter.reset()
      Application.delete_env(:edge_proxy, :rate_limit)
      Runtime.set_circuit_breaker("flaky_tenant", :closed)
      Runtime.update([])
    end)

    :ok
  end

  test "enforces per-tenant request quota and returns 429 with retry-after" do
    port = 4093
    {:ok, _} = start_supervised({FlakyUpstream, []}, id: :rl_flaky_agent)
    {:ok, _} = start_supervised({Bandit, plug: FlakyUpstream, port: port, startup_log: false}, id: :rl_bandit)

    Runtime.update([
      %{
        tenant: "tenant_a",
        host: "rl.mesh.local",
        path: "/",
        upstream: {:http, "127.0.0.1", port}
      }
    ])

    :sys.get_state(Runtime)

    req = fn ->
      conn(:get, "http://mesh.local")
      |> put_req_header("x-edge-tenant", "tenant_a")
      |> EdgeProxy.call([])
    end

    assert req.().status == 200
    assert req.().status == 200

    blocked = req.()
    assert blocked.status == 429
    assert [retry] = get_resp_header(blocked, "retry-after")
    assert String.to_integer(retry) >= 1
  end

  test "HealthChecker automatically opens circuit breaker on failures and closes on recovery" do
    port = 4094
    {:ok, _} = start_supervised({FlakyUpstream, []}, id: :hc_flaky_agent)
    {:ok, _} = start_supervised({Bandit, plug: FlakyUpstream, port: port, startup_log: false}, id: :hc_bandit)

    # Disable rate limiting for health check test
    Application.put_env(:edge_proxy, :rate_limit, enabled: false)

    Runtime.update([
      %{
        tenant: "flaky_tenant",
        host: "hc.mesh.local",
        path: "/",
        upstream: {:http, "127.0.0.1", port}
      }
    ])

    :sys.get_state(Runtime)

    # Simulate upstream returning 503
    FlakyUpstream.set_status(503)

    # Default failure_threshold is 3
    HealthChecker.check_now()
    refute Runtime.circuit_open?("flaky_tenant")

    HealthChecker.check_now()
    refute Runtime.circuit_open?("flaky_tenant")

    HealthChecker.check_now()
    :sys.get_state(Runtime)
    assert Runtime.circuit_open?("flaky_tenant")

    # Gateway now rejects traffic with 503
    resp =
      conn(:get, "http://mesh.local")
      |> put_req_header("x-edge-tenant", "flaky_tenant")
      |> EdgeProxy.call([])

    assert resp.status == 503

    # Simulate upstream recovery (default recovery_threshold is 2)
    FlakyUpstream.set_status(200)
    HealthChecker.check_now()
    assert Runtime.circuit_open?("flaky_tenant")

    HealthChecker.check_now()
    :sys.get_state(Runtime)
    refute Runtime.circuit_open?("flaky_tenant")
  end
end
