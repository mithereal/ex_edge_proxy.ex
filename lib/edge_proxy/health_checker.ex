defmodule EdgeProxy.HealthChecker do
  @moduledoc """
  Periodic upstream health prober with automatic circuit-breaker tripping and recovery.

  Maintains a public ETS table (`:edge_proxy_upstream_health`) for lock-free lookups
  by `EdgeProxy.Routing.Balancer`, and opens per-tenant circuit breakers only when
  all targets for a tenant's route become unhealthy.

  Config options (under `:edge_proxy, :health_check`):
  - `enabled: true | false` (default: `false`)
  - `interval_ms: integer()` (default: `5_000`)
  - `timeout_ms: integer()` (default: `2_000`)
  - `path: String.t()` (default: `"/health"`)
  - `failure_threshold: integer()` (default: `3`)
  - `recovery_threshold: integer()` (default: `2`)
  """

  use GenServer
  require Logger

  alias EdgeProxy.Routing.Runtime

  @health_table :edge_proxy_upstream_health

  # ------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fast ETS lookup used by `EdgeProxy.Routing.Balancer` to skip unhealthy targets.
  Defaults to `true` if the upstream has not been probed yet.
  """
  def healthy?({scheme, host, port}) do
    case :ets.whereis(@health_table) do
      :undefined ->
        true

      _ ->
        case :ets.lookup(@health_table, {scheme, host, port}) do
          [{_, false}] -> false
          _ -> true
        end
    end
  end

  @doc """
  Triggers an immediate synchronous health check pass across all configured upstreams.
  """
  def check_now do
    GenServer.call(__MODULE__, :check_now, 15_000)
  end

  @doc """
  Returns the current health tracking map keyed by `{scheme, host, port}`.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ------------------------------------------------------------
  # GEN_SERVER CALLBACKS
  # ------------------------------------------------------------

  @impl true
  def init(opts) do
    :ets.new(@health_table, [:named_table, :public, :set, read_concurrency: true])

    state = %{
      overrides: opts,
      upstreams: %{}
    }

    if enabled?(state) do
      schedule_check(interval_ms(state))
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    new_state = run_checks(state)
    {:reply, new_state.upstreams, new_state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.upstreams, state}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state =
      if enabled?(state) do
        run_checks(state)
      else
        state
      end

    schedule_check(interval_ms(new_state))
    {:noreply, new_state}
  end

  # ------------------------------------------------------------
  # PROBING & CIRCUIT TRIPPING
  # ------------------------------------------------------------

  defp run_checks(state) do
    routes = Runtime.routes()

    unique_targets =
      routes
      |> Enum.flat_map(&route_targets/1)
      |> Enum.uniq()

    updated_upstreams =
      Enum.reduce(unique_targets, %{}, fn upstream_key, acc ->
        prev = Map.get(state.upstreams, upstream_key, %{failures: 0, successes: 0, healthy?: true})
        result = probe_upstream(upstream_key, state)
        next = evaluate_target_health(upstream_key, prev, result, state)
        :ets.insert(@health_table, {upstream_key, next.healthy?})
        EdgeProxy.Telemetry.emit_upstream_health(upstream_key, next.healthy?)
        Map.put(acc, upstream_key, next)
      end)

    sync_tenant_circuits(routes, updated_upstreams)
    %{state | upstreams: updated_upstreams}
  end

  defp probe_upstream({scheme, host, port}, state) do
    path = opt(state, :path, "/health")
    timeout = opt(state, :timeout_ms, 2_000)

    with {:ok, conn} <- Mint.HTTP.connect(scheme, host, port, transport_opts: [timeout: timeout]),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, "GET", path, [], nil),
         {:ok, conn, status} <- await_status(conn, ref, nil, timeout) do
      Mint.HTTP.close(conn)
      if status in 200..399, do: :ok, else: {:error, {:bad_status, status}}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp await_status(conn, ref, status, timeout) do
    receive do
      msg ->
        case Mint.HTTP.stream(conn, msg) do
          {:ok, conn, responses} ->
            {status, done?} =
              Enum.reduce(responses, {status, false}, fn
                {:status, ^ref, s}, {_s, d} -> {s, d}
                {:done, ^ref}, {s, _d} -> {s, true}
                _, acc -> acc
              end)

            if done? do
              {:ok, conn, status}
            else
              await_status(conn, ref, status, timeout)
            end

          {:error, _conn, reason, _responses} ->
            {:error, reason}

          :unknown ->
            await_status(conn, ref, status, timeout)
        end
    after
      timeout -> {:error, :timeout}
    end
  end

  defp evaluate_target_health(upstream_key, prev, :ok, state) do
    recovery_threshold = opt(state, :recovery_threshold, 2)
    successes = prev.successes + 1

    if not prev.healthy? and successes >= recovery_threshold do
      Logger.info("[EdgeProxy.HealthChecker] Upstream #{inspect(upstream_key)} recovered.")
      %{failures: 0, successes: successes, healthy?: true}
    else
      %{failures: 0, successes: successes, healthy?: prev.healthy?}
    end
  end

  defp evaluate_target_health(upstream_key, prev, {:error, reason}, state) do
    failure_threshold = opt(state, :failure_threshold, 3)
    failures = prev.failures + 1

    if prev.healthy? and failures >= failure_threshold do
      Logger.warning(
        "[EdgeProxy.HealthChecker] Upstream #{inspect(upstream_key)} marked unhealthy (#{inspect(reason)})."
      )

      %{failures: failures, successes: 0, healthy?: false}
    else
      %{failures: failures, successes: 0, healthy?: prev.healthy?}
    end
  end

  # Opens a tenant's circuit breaker only when ALL targets for that tenant's routes are unhealthy
  defp sync_tenant_circuits(routes, upstreams_map) do
    routes
    |> Enum.reject(&(&1.tenant in [nil, :any]))
    |> Enum.group_by(& &1.tenant)
    |> Enum.each(fn {tenant, tenant_routes} ->
      targets =
        tenant_routes
        |> Enum.flat_map(&route_targets/1)
        |> Enum.uniq()

      any_healthy? =
        Enum.any?(targets, fn key ->
          get_in(upstreams_map, [key, :healthy?]) != false
        end)

      cond do
        not any_healthy? and not Runtime.circuit_open?(tenant) ->
          Logger.warning("[EdgeProxy.HealthChecker] All upstreams down for #{tenant}; opening circuit.")
          Runtime.set_circuit_breaker(tenant, :open)

        any_healthy? and Runtime.circuit_open?(tenant) ->
          Logger.info("[EdgeProxy.HealthChecker] Healthy upstream available for #{tenant}; closing circuit.")
          Runtime.set_circuit_breaker(tenant, :closed)

        true ->
          :ok
      end
    end)
  end

  defp route_targets(%{upstream: list}) when is_list(list) do
    Enum.map(list, fn u -> {u.scheme, u.host, u.port} end)
  end

  defp route_targets(%{upstream: u}) when is_map(u) do
    [{u.scheme, u.host, u.port}]
  end

  defp enabled?(state), do: opt(state, :enabled, false)
  defp interval_ms(state), do: opt(state, :interval_ms, 5_000)

  defp opt(state, key, default) do
    Keyword.get(
      state.overrides,
      key,
      Keyword.get(Application.get_env(:edge_proxy, :health_check, []), key, default)
    )
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :tick, interval)
  end
end
