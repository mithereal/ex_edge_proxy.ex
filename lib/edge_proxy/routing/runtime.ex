defmodule EdgeProxy.Routing.Runtime do
  @moduledoc """
  Single source of truth for EdgeProxy routing and circuit breakers (backed by ETS).
  """

  use GenServer

  alias EdgeProxy.Routing.PathRouter

  @table :edge_proxy_routes

  defstruct routes: [],
            circuit_breakers: %{}

  # ------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------

  def resolve(conn) do
    PathRouter.resolve(conn)
  end

  def routes do
    case :ets.lookup(@table, :routes) do
      [{:routes, routes}] -> routes
      _ -> []
    end
  end

  def update(new_routes) when is_list(new_routes) do
    GenServer.cast(__MODULE__, {:update_routes, new_routes})
  end

  def put_domain(domain, routes) when is_list(routes) do
    GenServer.call(__MODULE__, {:put_domain, domain, routes})
  end

  def put_wildcard(pattern, routes) when is_list(routes) do
    GenServer.call(__MODULE__, {:put_wildcard, pattern, routes})
  end

  def delete_domain(domain) do
    GenServer.call(__MODULE__, {:delete_domain, domain})
  end

  def set_circuit_breaker(tenant, state) when state in [:open, :closed] do
    GenServer.cast(__MODULE__, {:circuit, tenant, state})
  end

  def circuit_open?(nil), do: false

  def circuit_open?(tenant) do
    case :ets.lookup(@table, {:circuit, tenant}) do
      [{_, :open}] -> true
      _ -> false
    end
  end

  # ------------------------------------------------------------
  # GEN_SERVER
  # ------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    :ets.insert(table, {:routes, []})
    {:ok, state}
  end

  @impl true
  def handle_call({:put_domain, domain, domain_routes}, _from, state) do
    normalized =
      domain_routes
      |> Enum.map(&Map.put(&1, :host, domain))
      |> normalize_routes()

    updated =
      state.routes
      |> Enum.reject(&(&1.host == domain))
      |> Kernel.++(normalized)

    :ets.insert(@table, {:routes, updated})
    {:reply, :ok, %{state | routes: updated}}
  end

  def handle_call({:put_wildcard, pattern, wildcard_routes}, _from, state) do
    normalized =
      wildcard_routes
      |> Enum.map(&Map.put(&1, :host, pattern))
      |> normalize_routes()

    updated =
      state.routes
      |> Enum.reject(&(&1.host == pattern))
      |> Kernel.++(normalized)

    :ets.insert(@table, {:routes, updated})
    {:reply, :ok, %{state | routes: updated}}
  end

  def handle_call({:delete_domain, domain}, _from, state) do
    updated = Enum.reject(state.routes, &(&1.host == domain))
    :ets.insert(@table, {:routes, updated})
    {:reply, :ok, %{state | routes: updated}}
  end

  @impl true
  def handle_cast({:update_routes, routes}, state) do
    normalized = normalize_routes(routes)
    :ets.insert(@table, {:routes, normalized})
    {:noreply, %{state | routes: normalized}}
  end

  def handle_cast({:circuit, tenant, state_flag}, state) do
    :ets.insert(@table, {{:circuit, tenant}, state_flag})
    breakers = Map.put(state.circuit_breakers, tenant, state_flag)
    {:noreply, %{state | circuit_breakers: breakers}}
  end

  # ------------------------------------------------------------
  # NORMALIZATION
  # ------------------------------------------------------------

  defp normalize_routes(routes) do
    Enum.map(routes, &normalize_route/1)
  end

  defp normalize_route(route) do
    %{
      tenant: normalize_tenant(Map.get(route, :tenant, :any)),
      host: Map.get(route, :host, :any),
      path: Map.get(route, :path, :any),
      upstream: normalize_upstream(Map.fetch!(route, :upstream)),
      opts: Map.get(route, :opts, %{})
    }
  end

  defp normalize_tenant("any"), do: :any
  defp normalize_tenant(val), do: val

  defp normalize_upstream({:http, host, port}), do: %{scheme: :http, host: host, port: port}
  defp normalize_upstream({:https, host, port}), do: %{scheme: :https, host: host, port: port}

  defp normalize_upstream(%{"type" => scheme, "host" => host, "port" => port}) do
    %{scheme: String.to_existing_atom(scheme), host: host, port: port}
  end

  defp normalize_upstream(%{} = map) do
    Map.put_new(map, :scheme, :http)
  end
end
