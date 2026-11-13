defmodule EdgeProxy.MeshBridgeTest do
  use ExUnit.Case, async: false

  alias EdgeProxy.MeshBridge
  alias EdgeProxy.Routing.Runtime

  setup do
    Runtime.update([
      %{
        tenant: :any,
        host: "static.mesh.local",
        path: "/",
        upstream: {:http, "127.0.0.1", 4010},
        opts: %{source: :static}
      }
    ])

    :sys.get_state(Runtime)

    on_exit(fn ->
      Runtime.update([])
      :code.purge(Router.Registry)
      :code.delete(Router.Registry)
    end)

    :ok
  end


  test "syncs discovered services from Router.Registry into Runtime and preserves static routes" do
    # Define a mock Router.Registry if :ex_service_mesh_router is not in deps
    unless Code.ensure_loaded?(Router.Registry) do
      defmodule Router.Registry do
        def list_routes do
          [
            {"auth.mesh.local", %{ip: {10, 0, 0, 2}, port: 4001, node: :auth@mesh}},
            {"billing.mesh.local", %{host: "10.0.0.3", port: 4002, path: "/billing"}}
          ]
        end
      end
    end

    assert MeshBridge.mesh_available?()

    {:ok, bridge_pid} = start_supervised({MeshBridge, sync_interval: 60_000})
    assert {:ok, 4} = MeshBridge.sync_now()
    :sys.get_state(Runtime)

    routes = Runtime.routes()

    # Static route is still intact
    assert Enum.any?(routes, &(&1.host == "static.mesh.local"))

    # Exact and wildcard mesh routes were added for both services
    assert Enum.any?(routes, &(&1.host == "auth.mesh.local" and &1.upstream.port == 4001))
    assert Enum.any?(routes, &(&1.host == "*.auth.mesh.local" and &1.upstream.port == 4001))
    assert Enum.any?(routes, &(&1.host == "billing.mesh.local" and &1.path == "/billing"))
    assert Enum.any?(routes, &(&1.host == "*.billing.mesh.local" and &1.path == "/billing"))

    stop_supervised(MeshBridge)
    refute Process.alive?(bridge_pid)
  end

  test "prunes stale mesh routes when a node disconnects from Router.Registry" do
    defmodule DynamicMockRegistry do
      use Agent

      def start_link(initial), do: Agent.start_link(fn -> initial end, name: __MODULE__)
      def set(entries), do: Agent.update(__MODULE__, fn _ -> entries end)
      def get, do: Agent.get(__MODULE__, & &1)
    end

    {:ok, _} =
      start_supervised(
        {DynamicMockRegistry, [{"temp.mesh.local", %{ip: "127.0.0.1", port: 4055}}]}
      )

    # Temporarily point Router.Registry.list_routes/0 to the Agent
    Code.compiler_options(ignore_module_conflict: true)

    defmodule Router.Registry do
      def list_routes, do: EdgeProxy.MeshBridgeTest.DynamicMockRegistry.get()
    end

    Code.compiler_options(ignore_module_conflict: false)

    {:ok, _bridge} = start_supervised({MeshBridge, sync_interval: 60_000})
    assert {:ok, 2} = MeshBridge.sync_now()
    :sys.get_state(Runtime)

    assert Enum.any?(Runtime.routes(), &(&1.host == "temp.mesh.local"))

    # Simulate node crash / deregistration in Router.Registry
    DynamicMockRegistry.set([])
    assert {:ok, 0} = MeshBridge.sync_now()
    :sys.get_state(Runtime)

    refute Enum.any?(Runtime.routes(), &(&1.host == "temp.mesh.local"))
    assert Enum.any?(Runtime.routes(), &(&1.host == "static.mesh.local"))
  end
end
