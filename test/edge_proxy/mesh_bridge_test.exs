defmodule EdgeProxy.MeshBridgeTest do
  use ExUnit.Case, async: false

  alias EdgeProxy.MeshBridge
  alias EdgeProxy.Routing.Runtime

  defmodule MockRouterRegistry do
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, opts)
    def put(host, target), do: GenServer.call(Router.Registry, {:put, host, target})
    def delete(host), do: GenServer.call(Router.Registry, {:delete, host})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:put, host, target}, _from, state) do
      {:reply, :ok, Map.put(state, host, target)}
    end

    def handle_call({:delete, host}, _from, state) do
      {:reply, :ok, Map.delete(state, host)}
    end
  end

  setup do
    original_routes = Runtime.routes()
    original_patterns = Application.get_env(:edge_proxy, :internal_host_patterns)

    # Seed a static route to verify MeshBridge preserves non-mesh routes
    static_route = %{
      tenant: :any,
      host: "static.mesh.local",
      path: "/",
      upstream: %{scheme: :http, host: "127.0.0.1", port: 4099},
      opts: %{source: :static}
    }

    Runtime.update([static_route])

    # Stop existing bridge/registry if started by application supervision tree
    if pid = Process.whereis(MeshBridge), do: GenServer.stop(pid)
    if pid = Process.whereis(Router.Registry), do: GenServer.stop(pid)

    {:ok, _reg_pid} = MockRouterRegistry.start_link(name: Router.Registry)
    {:ok, _bridge_pid} = MeshBridge.start_link(sync_interval: 60_000)

    on_exit(fn ->
      if pid = Process.whereis(MeshBridge), do: GenServer.stop(pid)
      if pid = Process.whereis(Router.Registry), do: GenServer.stop(pid)
      Runtime.update(original_routes)

      if is_nil(original_patterns) do
        Application.delete_env(:edge_proxy, :internal_host_patterns)
      else
        Application.put_env(:edge_proxy, :internal_host_patterns, original_patterns)
      end
    end)

    :ok
  end

  test "syncs public mesh services while excluding *.internal.mesh.local and internal: true" do
    MockRouterRegistry.put("auth.mesh.local", %{ip: {10, 0, 0, 2}, port: 4001})
    MockRouterRegistry.put("payments.internal.mesh.local", %{ip: {10, 0, 0, 3}, port: 4002})
    MockRouterRegistry.put("audit.mesh.local", %{ip: {10, 0, 0, 4}, port: 4003, internal: true})

    assert {:ok, 2} = MeshBridge.sync_now()

    hosts = Enum.map(Runtime.routes(), & &1.host)

    # Preserves static route
    assert "static.mesh.local" in hosts

    # Syncs public mesh route (exact + wildcard subdomain)
    assert "auth.mesh.local" in hosts
    assert "*.auth.mesh.local" in hosts

    # Excludes internal services from public EdgeProxy runtime
    refute "payments.internal.mesh.local" in hosts
    refute "*.payments.internal.mesh.local" in hosts
    refute "audit.mesh.local" in hosts
  end

  test "prunes routes when services are removed from Router.Registry" do
    MockRouterRegistry.put("billing.mesh.local", %{ip: "10.0.0.5", port: 4005})
    assert {:ok, 2} = MeshBridge.sync_now()
    assert Enum.any?(Runtime.routes(), &(&1.host == "billing.mesh.local"))

    MockRouterRegistry.delete("billing.mesh.local")
    assert {:ok, 0} = MeshBridge.sync_now()
    refute Enum.any?(Runtime.routes(), &(&1.host == "billing.mesh.local"))
  end
end
