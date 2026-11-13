defmodule EdgeProxy.Routing.PathRouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias EdgeProxy.Routing.{PathRouter, Runtime}

  setup do
    Runtime.update([
      %{
        tenant: "tenant1",
        host: "*.mesh.local",
        path: "/billing",
        upstream: {:http, "127.0.0.1", 4002}
      },
      %{
        tenant: :any,
        host: "auth.mesh.local",
        path: "/",
        upstream: {:http, "127.0.0.1", 4001}
      }
    ])

    # Allow async cast to flush into ETS
    :sys.get_state(Runtime)

    on_exit(fn ->
      Runtime.set_circuit_breaker("tenant1", :closed)
      Runtime.update([])
    end)

    :ok
  end

  test "matches wildcard subdomain and extracts tenant from subdomain" do
    conn = conn(:get, "http://mesh.local")

    assert {:ok, route} = PathRouter.resolve(conn)
    assert route.tenant == "tenant1"
    assert route.host == "tenant1.billing.mesh.local"
    assert route.upstream == %{scheme: :http, host: "127.0.0.1", port: 4002}
  end

  test "prefers explicit x-edge-tenant header over subdomain" do
    conn =
      conn(:get, "http://mesh.local")
      |> put_req_header("x-edge-tenant", "tenant1")

    assert {:ok, route} = PathRouter.resolve(conn)
    assert route.tenant == "tenant1"
  end

  test "matches :any tenant on exact host" do
    conn = conn(:get, "http://mesh.local")

    assert {:ok, route} = PathRouter.resolve(conn)
    assert route.upstream == %{scheme: :http, host: "127.0.0.1", port: 4001}
  end

  test "returns :no_route when host or path does not match" do
    conn = conn(:get, "http://example.com")
    assert {:error, :no_route} = PathRouter.resolve(conn)
  end

  test "blocks requests when tenant circuit breaker is open" do
    Runtime.set_circuit_breaker("tenant1", :open)
    :sys.get_state(Runtime)

    conn = conn(:get, "http://mesh.local")
    assert {:error, :circuit_open} = PathRouter.resolve(conn)
  end
end
