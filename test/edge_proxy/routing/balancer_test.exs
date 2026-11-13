defmodule EdgeProxy.Routing.BalancerTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias EdgeProxy.HealthChecker
  alias EdgeProxy.Routing.{PathRouter, Runtime}

  defmodule TaggedUpstream do
    use Plug.Builder

    plug :respond

    def respond(conn, opts) do
      Plug.Conn.send_resp(conn, 200, opts[:tag])
    end
  end

  setup do
    on_exit(fn ->
      Runtime.update([])
      if :ets.whereis(:edge_proxy_upstream_health) != :undefined do
        :ets.delete_all_objects(:edge_proxy_upstream_health)
      end
    end)

    :ok
  end

  test "distributes traffic proportionally across weighted upstreams" do
    Runtime.update([
      %{
        tenant: :any,
        host: "lb.mesh.local",
        path: "/",
        upstreams: [
          {:http, "127.0.0.1", 4081, 80},
          {:http, "127.0.0.1", 4082, 20}
        ]
      }
    ])

    :sys.get_state(Runtime)

    counts =
      1..1_000
      |> Enum.reduce(%{4081 => 0, 4082 => 0}, fn _, acc ->
        {:ok, route} = PathRouter.resolve(conn(:get, "http://mesh.local"))
        Map.update!(acc, route.upstream.port, &(&1 + 1))
      end)

    # With 80/20 weights over 1,000 requests, 4081 should receive ~720-880 requests
    assert counts[4081] in 700..900
    assert counts[4082] in 100..300
  end

  test "automatically excludes unhealthy targets and routes 100% to healthy nodes" do
    {:ok, _} =
      start_supervised(
        {Bandit, plug: {TaggedUpstream, tag: "node_b"}, port: 4084, startup_log: false},
        id: :healthy_lb_node
      )

    # Port 4083 is intentionally not listening (unhealthy)
    Runtime.update([
      %{
        tenant: :any,
        host: "failover.mesh.local",
        path: "/",
        upstreams: [
          {:http, "127.0.0.1", 4083, 90},
          {:http, "127.0.0.1", 4084, 10}
        ]
      }
    ])

    :sys.get_state(Runtime)

    # Run 3 health check passes to trip 4083 out of rotation
    HealthChecker.check_now()
    HealthChecker.check_now()
    HealthChecker.check_now()

    refute HealthChecker.healthy?({:http, "127.0.0.1", 4083})
    assert HealthChecker.healthy?({:http, "127.0.0.1", 4084})

    # Every request now lands on healthy node_b (4084)
    for _ <- 1..10 do
      resp = conn(:get, "http://mesh.local") |> EdgeProxy.call([])
      assert resp.status == 200
      assert resp.resp_body == "node_b"
    end
  end
end
