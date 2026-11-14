defmodule EdgeProxy.LoadSimulator do
  @moduledoc """
  Multi-tenant load and chaos generator for EdgeProxy.

  Generates:
  1. Steady concurrent traffic across multiple tenants (`tenant1`, `tenant2`, `enterprise_tenant`)
  2. Burst traffic on `noisy_tenant` to trigger 429 rate-limit rejections
  3. Optional circuit-breaker trip + recovery cycle to test Prometheus & Alertmanager alerts
  """

  alias EdgeProxy.Control.Client

  @default_url "http://127.0.0.1:4000"
  @control_url "http://127.0.0__"

  def run(opts \\ []) do
    :inets.start()
    :ssl.start()

    base_url = Keyword.get(opts, :url, @default_url)
    duration_sec = Keyword.get(opts, :duration, 60)
    concurrency = Keyword.get(opts, :concurrency, 12)
    chaos? = Keyword.get(opts, :chaos, true)

    IO.puts("🚀 Starting EdgeProxy load test against #{base_url}")
    IO.puts("   Duration: #{duration_sec}s | Concurrency: #{concurrency} | Chaos alerts: #{chaos?}")

    deadline = System.monotonic_time(:second) + duration_sec

    # Optional chaos task: trips `chaos_tenant` circuit breaker for 20s to fire EdgeProxyCircuitBreakerOpen
    chaos_task =
      if chaos? do
        Task.async(fn -> run_chaos_cycle() end)
      end

    # Concurrent worker pool sending weighted multi-tenant requests
    results =
      1..concurrency
      |> Task.async_stream(
        fn worker_id -> worker_loop(worker_id, base_url, deadline, %{}) end,
        max_concurrency: concurrency,
        timeout: (duration_sec + 15) * 1_000
      )
      |> Enum.reduce(%{}, fn {:ok, worker_stats}, acc ->
        Map.merge(acc, worker_stats, fn _k, v1, v2 -> v1 + v2 end)
      end)

    if chaos_task, do: Task.await(chaos_task, 30_000)

    print_summary(results, duration_sec)
  end

  defp worker_loop(worker_id, base_url, deadline, stats) do
    if System.monotonic_time(:second) >= deadline do
      stats
    else
      {tenant, host, path} = pick_scenario(worker_id)
      status = send_request(base_url, host, tenant, path)
      updated = Map.update(stats, {tenant, status}, 1, &(&1 + 1))

      # Small jitter to vary RPS naturally
      Process.sleep(:rand.uniform(40))
      worker_loop(worker_id, base_url, deadline, updated)
    end
  end

  defp pick_scenario(_worker_id) do
    case :rand.uniform(100) do
      # 45% normal traffic to Auth service
      n when n <= 45 ->
        {"tenant1", "tenant1.auth.mesh.local", "/login"}

      # 30% normal traffic to Billing service
      n when n <= 75 ->
        {"enterprise_tenant", "enterprise.billing.mesh.local", "/billing/invoices"}

      # 20% burst traffic on noisy_tenant (triggers 429 rate limits)
      n when n <= 95 ->
        {"noisy_tenant", "noisy.billing.mesh.local", "/billing/export"}

      # 5% traffic to chaos_tenant (shows 503s while circuit breaker is open)
      _ ->
        {"chaos_tenant", "chaos.auth.mesh.local", "/profile"}
    end
  end

  defp send_request(base_url, host, tenant, path) do
    url = String.to_charlist("#{base_url}#{path}")

    headers = [
      {~c"host", String.to_charlist(host)},
      {~c"x-edge-tenant", String.to_charlist(tenant)},
      {~c"x-request-id", String.to_charlist(Base.encode16(:crypto.strong_rand_bytes(6), case: :lower))}
    ]

    case :httpc.request(:get, {url, headers}, [timeout: 3_000, connect_timeout: 2_000], []) do
      {:ok, {{_v, status, _r}, _headers, _body}} -> status
      {:error, _reason} -> :transport_error
    end
  end

  defp run_chaos_cycle do
    Process.sleep(5_000)
    IO.puts("\n⚡ [Chaos] Opening circuit breaker for 'chaos_tenant' (watch Prometheus/Alertmanager)...")
    Client.set_circuit_breaker("chaos_tenant", :open, url: @control_url)

    # Keep open for 20s so Prometheus `for: 15s` rule transitions from PENDING -> FIRING
    Process.sleep(20_000)

    IO.puts("✅ [Chaos] Closing circuit breaker for 'chaos_tenant' (alert will auto-resolve)...")
    Client.set_circuit_breaker("chaos_tenant", :closed, url: @control_url)
  end

  defp print_summary(stats, duration_sec) do
    total = stats |> Map.values() |> Enum.sum()
    rps = Float.round(total / max(duration_sec, 1), 1)

    IO.puts("\n📊 Load Test Summary (#{total} total requests | ~#{rps} req/s)")
    IO.puts(String.duplicate("-", 52))

    stats
    |> Enum.sort_by(fn {{tenant, status}, _count} -> {tenant, status} end)
    |> Enum.each(fn {{tenant, status}, count} ->
      IO.puts("  #{String.pad_trailing(tenant, 22)} | status: #{String.pad_trailing(to_string(status), 15)} | #{count}")
    end)
  end
end

# Parse CLI flags: --url, --duration, --concurrency, --no-chaos
{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [url: :string, duration: :integer, concurrency: :integer, chaos: :boolean]
  )

EdgeProxy.LoadSimulator.run(opts)
