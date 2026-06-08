defmodule EdgeProxy.Routing.Runtime do
  @moduledoc """
  Runtime routing state for EdgeProxy.

  Responsibilities:
  - hold routing table in memory
  - resolve requests via PathRouter
  - manage circuit breaker state
  - support hot updates (no restart required)

  Single-node only. No distributed sync.
  """

  use GenServer

  alias EdgeProxy.Routing.PathRouter

  @table :edge_proxy_routes

  # ------------------------------------------------------------
  # STATE
  # ------------------------------------------------------------

  defstruct routes: [],
            circuit_breakers: %{}

  # ------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------

  @doc """
  Resolve a Plug.Conn into an upstream route.
  """
  def resolve(conn) do
    PathRouter.resolve(conn)
  end

  @doc """
  Return current routing table (fast path via ETS).
  """
  def routes do
    case :ets.lookup(@table, :routes) do
      [{:routes, routes}] -> routes
      _ -> []
    end
  end

  @doc """
  Replace routing table at runtime.
  """
  def update(new_routes) when is_list(new_routes) do
    GenServer.cast(__MODULE__, {:update_routes, new_routes})
  end

  @doc """
  Enable/disable circuit breaker for a tenant.
  """
  def set_circuit_breaker(tenant, state)
      when state in [:open, :closed] do
    GenServer.cast(__MODULE__, {:circuit, tenant, state})
  end

  @doc """
  Check if tenant is currently blocked.
  """
  def circuit_open?(tenant) do
    case :ets.lookup(@table, {:circuit, tenant}) do
      [{_, :open}] -> true
      _ -> false
    end
  end

  # ------------------------------------------------------------
  # GEN SERVER
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

  # ------------------------------------------------------------
  # CALLS
  # ------------------------------------------------------------

  @impl true
  def handle_call(:routes, _from, state) do
    {:reply, state.routes, state}
  end

  # kept for compatibility (optional slow path)
  def handle_call({:circuit_open?, tenant}, _from, state) do
    open? =
      Map.get(state.circuit_breakers, tenant, :closed) == :open

    {:reply, open?, state}
  end

  # ------------------------------------------------------------
  # CASTS
  # ------------------------------------------------------------

  @impl true
  def handle_cast({:update_routes, routes}, state) do
    normalized = normalize_routes(routes)

    :ets.insert(@table, {:routes, normalized})

    {:noreply, %{state | routes: normalized}}
  end

  def handle_cast({:circuit, tenant, state_flag}, state) do
    :ets.insert(@table, {{:circuit, tenant}, state_flag})

    breakers =
      Map.put(state.circuit_breakers, tenant, state_flag)

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
      tenant: Map.get(route, :tenant, :any),
      host: Map.get(route, :host, :any),
      path: Map.get(route, :path, :any),
      upstream: normalize_upstream(Map.fetch!(route, :upstream)),
      opts: Map.get(route, :opts, %{})
    }
  end

  # ------------------------------------------------------------
  # UPSTREAM NORMALIZATION
  # ------------------------------------------------------------

  defp normalize_upstream({:http, host, port}) do
    %{scheme: :http, host: host, port: port}
  end

  defp normalize_upstream({:https, host, port}) do
    %{scheme: :https, host: host, port: port}
  end

  defp normalize_upstream(%{} = map) do
    map
  end
end