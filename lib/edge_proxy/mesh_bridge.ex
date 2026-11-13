defmodule EdgeProxy.MeshBridge do
  @moduledoc """
  Bridges `ExServiceMeshRouter` dynamic service discovery into `EdgeProxy.Routing.Runtime`.

  Responsibilities:
  - Reads live upstream registrations from `Router.Registry` (when available)
  - Converts discovered mesh endpoints into `EdgeProxy` routes (`source: :mesh`)
  - Preserves static (`routes.json`) and control-plane (`/__edge_control__`) routes
  - Automatically prunes routes when `Router.Registry` removes crashed/disconnected nodes
  """

  use GenServer
  require Logger

  alias EdgeProxy.Routing.Runtime

  @compile {:no_warn_undefined, Router.Registry}


  @default_sync_interval 2_000

  # ------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Force an immediate synchronization from `Router.Registry` into `EdgeProxy.Routing.Runtime`.
  """
  def sync_now do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :sync_now)
    else
      {:error, :bridge_not_running}
    end
  end

  @doc """
  Returns true if `:ex_service_mesh_router` is compiled and loaded.
  """
  def mesh_available? do
    Code.ensure_loaded?(Router.Registry)
  end

  # ------------------------------------------------------------
  # GEN_SERVER CALLBACKS
  # ------------------------------------------------------------

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :sync_interval, @default_sync_interval)

    if mesh_available?() do
      ensure_mesh_registry_started()
      perform_sync()
      schedule_sync(interval)
      {:ok, %{interval: interval, last_hash: nil}}
    else
      Logger.info("[EdgeProxy.MeshBridge] :ex_service_mesh_router not loaded; bridge idle.")
      {:ok, %{interval: interval, last_hash: :disabled}}
    end
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    count = perform_sync()
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_info(:sync, %{last_hash: :disabled} = state) do
    {:noreply, state}
  end

  def handle_info(:sync, state) do
    perform_sync()
    schedule_sync(state.interval)
    {:noreply, state}
  end

  # ------------------------------------------------------------
  # SYNC & TRANSLATION LOGIC
  # ------------------------------------------------------------

  defp ensure_mesh_registry_started do
    if Code.ensure_loaded?(Router.Registry) and is_nil(Process.whereis(Router.Registry)) do
      case Router.Registry.start_link(name: Router.Registry) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        other -> Logger.warning("[EdgeProxy.MeshBridge] Could not start Router.Registry: #{inspect(other)}")
      end
    end
  end

  defp perform_sync do
    mesh_routes =
      fetch_mesh_entries()
      |> Enum.flat_map(&entry_to_edge_routes/1)

    merge_into_runtime(mesh_routes)
    length(mesh_routes)
  end

  # Supports common Router.Registry inspection APIs or ETS state
  defp fetch_mesh_entries do
    cond do
      function_exported?(Router.Registry, :list_routes, 0) ->
        Router.Registry.list_routes()

      function_exported?(Router.Registry, :all, 0) ->
        Router.Registry.all()

      Process.whereis(Router.Registry) != nil ->
        extract_from_registry_state(Process.whereis(Router.Registry))

      true ->
        []
    end
  rescue
    error ->
      Logger.warning("[EdgeProxy.MeshBridge] Failed reading Router.Registry: #{inspect(error)}")
      []
  end

  defp extract_from_registry_state(pid) do
    case :sys.get_state(pid) do
      %{routes: routes} when is_map(routes) -> Map.to_list(routes)
      map when is_map(map) -> Map.to_list(map)
      list when is_list(list) -> list
      _ -> []
    end
  end

  # Translates {host_key, target_info} from Router.Registry into EdgeProxy route maps
  defp entry_to_edge_routes({host, %{ip: ip, port: port} = meta}) do
    build_routes(host, ip, port, meta)
  end

  defp entry_to_edge_routes({host, %{host: ip, port: port} = meta}) do
    build_routes(host, ip, port, meta)
  end

  defp entry_to_edge_routes({host, {ip, port}}) do
    build_routes(host, ip, port, %{})
  end

  defp entry_to_edge_routes(_other), do: []

  defp build_routes(host, ip, port, meta) do
    normalized_host = to_string(host)
    normalized_ip = format_ip(ip)
    scheme = Map.get(meta, :scheme, :http)

    # Support both exact service host ("auth.mesh.local") and tenant subdomains ("*.auth.mesh.local")
    [
      %{
        tenant: :any,
        host: normalized_host,
        path: Map.get(meta, :path, "/"),
        upstream: %{scheme: scheme, host: normalized_ip, port: port},
        opts: %{source: :mesh, node: Map.get(meta, :node)}
      },
      %{
        tenant: :any,
        host: "*.#{normalized_host}",
        path: Map.get(meta, :path, "/"),
        upstream: %{scheme: scheme, host: normalized_ip, port: port},
        opts: %{source: :mesh, node: Map.get(meta, :node)}
      }
    ]
  end

  defp merge_into_runtime(mesh_routes) do
    non_mesh_routes =
      Runtime.routes()
      |> Enum.reject(fn route -> get_in(route, [:opts, :source]) == :mesh end)

    Runtime.update(non_mesh_routes ++ mesh_routes)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(ip) when is_atom(ip), do: Atom.to_string(ip)

  defp schedule_sync(interval) do
    Process.send_after(self(), :sync, interval)
  end
end
