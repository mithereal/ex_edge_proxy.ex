defmodule EdgeProxy.Telemetry do
  @moduledoc """
  Emits `:telemetry` events and aggregates Prometheus-compatible metrics in ETS.

  Tracked metrics:
  - `edge_proxy_requests_total` (counter by tenant, method, status)
  - `edge_proxy_request_duration_seconds` (histogram by tenant)
  - `edge_proxy_rate_limited_total` (counter by tenant)
  - `edge_proxy_circuit_breaker_state` (gauge by tenant: 1 = open, 0 = closed)
  - `edge_proxy_upstream_healthy` (gauge by upstream: 1 = healthy, 0 = unhealthy)
  """

  use GenServer

  @table :edge_proxy_metrics
  @handler_id "edge-proxy-prometheus-collector"
  @buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]

  # ------------------------------------------------------------
  # EVENT EMISSION HELPERS
  # ------------------------------------------------------------

  def emit_request(duration_native, tenant, method, status) do
    :telemetry.execute(
      [:edge_proxy, :request, :stop],
      %{duration: duration_native},
      %{tenant: tenant || "none", method: method, status: status}
    )
  end

  def emit_rate_limited(tenant) do
    :telemetry.execute(
      [:edge_proxy, :rate_limit, :hit],
      %{count: 1},
      %{tenant: tenant || "none"}
    )
  end

  def emit_circuit_breaker(tenant, state) when state in [:open, :closed] do
    :telemetry.execute(
      [:edge_proxy, :circuit_breaker, :transition],
      %{state: if(state == :open, do: 1, else: 0)},
      %{tenant: tenant || "none"}
    )
  end

  def emit_upstream_health({scheme, host, port}, healthy?) do
    :telemetry.execute(
      [:edge_proxy, :upstream, :health],
      %{healthy: if(healthy?, do: 1, else: 0)},
      %{upstream: "#{scheme}://#{host}:#{port}"}
    )
  end

  # ------------------------------------------------------------
  # PROMETHEUS SCRAPE FORMATTER
  # ------------------------------------------------------------

  @doc """
  Renders all collected metrics in Prometheus text exposition format (v0.0.4).
  """
  def scrape do
    entries = if :ets.whereis(@table) != :undefined, do: :ets.tab2list(@table), else: []

    [
      render_request_counters(entries),
      render_duration_histograms(entries),
      render_rate_limit_counters(entries),
      render_circuit_gauges(entries),
      render_upstream_gauges(entries)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  def reset do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  # ------------------------------------------------------------
  # GEN_SERVER & TELEMETRY HANDLER
  # ------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

    events = [
      [:edge_proxy, :request, :stop],
      [:edge_proxy, :rate_limit, :hit],
      [:edge_proxy, :circuit_breaker, :transition],
      [:edge_proxy, :upstream, :health]
    ]

    :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, nil)

    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event([:edge_proxy, :request, :stop], %{duration: duration_native}, meta, _cfg) do
    if :ets.whereis(@table) != :undefined do
      %{tenant: tenant, method: method, status: status} = meta
      seconds = System.convert_time_unit(duration_native, :native, :microsecond) / 1_000_000

      :ets.update_counter(@table, {:req_total, tenant, method, status}, {2, 1}, {{:req_total, tenant, method, status}, 0})
      :ets.update_counter(@table, {:dur_count, tenant}, {2, 1}, {{:dur_count, tenant}, 0})
      :ets.update_counter(@table, {:dur_sum_us, tenant}, {2, round(seconds * 1_000_000)}, {{:dur_sum_us, tenant}, 0})

      Enum.each(@buckets, fn le ->
        if seconds <= le do
          :ets.update_counter(@table, {:dur_bucket, tenant, le}, {2, 1}, {{:dur_bucket, tenant, le}, 0})
        end
      end)
    end
  end

  def handle_event([:edge_proxy, :rate_limit, :hit], _meas, %{tenant: tenant}, _cfg) do
    if :ets.whereis(@table) != :undefined do
      :ets.update_counter(@table, {:rate_limited, tenant}, {2, 1}, {{:rate_limited, tenant}, 0})
    end
  end

  def handle_event([:edge_proxy, :circuit_breaker, :transition], %{state: val}, %{tenant: tenant}, _cfg) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {{:circuit_state, tenant}, val})
    end
  end

  def handle_event([:edge_proxy, :upstream, :health], %{healthy: val}, %{upstream: upstream}, _cfg) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {{:upstream_health, upstream}, val})
    end
  end

  # ------------------------------------------------------------
  # TEXT FORMAT RENDERERS
  # ------------------------------------------------------------

  defp render_request_counters(entries) do
    rows =
      for {{:req_total, tenant, method, status}, val} <- entries do
        ~s(edge_proxy_requests_total{tenant="#{escape(tenant)}",method="#{escape(method)}",status="#{status}"} #{val})
      end

    format_block("edge_proxy_requests_total", "counter", "Total proxied HTTP/WS requests.", rows)
  end

  defp render_duration_histograms(entries) do
    tenants =
      for {{:dur_count, tenant}, _} <- entries, uniq: true, do: tenant

    rows =
      Enum.flat_map(tenants, fn tenant ->
        bucket_lines =
          Enum.map(@buckets, fn le ->
            count = lookup_val(entries, {:dur_bucket, tenant, le}, 0)
            ~s(edge_proxy_request_duration_seconds_bucket{tenant="#{escape(tenant)}",le="#{le}"} #{count})
          end)

        total_count = lookup_val(entries, {:dur_count, tenant}, 0)
        sum_sec = Float.round(lookup_val(entries, {:dur_sum_us, tenant}, 0) / 1_000_000, 6)

        bucket_lines ++
          [
            ~s(edge_proxy_request_duration_seconds_bucket{tenant="#{escape(tenant)}",le="+Inf"} #{total_count}),
            ~s(edge_proxy_request_duration_seconds_sum{tenant="#{escape(tenant)}"} #{sum_sec}),
            ~s(edge_proxy_request_duration_seconds_count{tenant="#{escape(tenant)}"} #{total_count})
          ]
      end)

    format_block("edge_proxy_request_duration_seconds", "histogram", "Request latency in seconds.", rows)
  end

  defp render_rate_limit_counters(entries) do
    rows =
      for {{:rate_limited, tenant}, val} <- entries do
        ~s(edge_proxy_rate_limited_total{tenant="#{escape(tenant)}"} #{val})
      end

    format_block("edge_proxy_rate_limited_total", "counter", "Total requests rejected with 429.", rows)
  end

  defp render_circuit_gauges(entries) do
    rows =
      for {{:circuit_state, tenant}, val} <- entries do
        ~s(edge_proxy_circuit_breaker_state{tenant="#{escape(tenant)}"} #{val})
      end

    format_block("edge_proxy_circuit_breaker_state", "gauge", "Circuit breaker state (1=open, 0=closed).", rows)
  end

  defp render_upstream_gauges(entries) do
    rows =
      for {{:upstream_health, upstream}, val} <- entries do
        ~s(edge_proxy_upstream_healthy{upstream="#{escape(upstream)}"} #{val})
      end

    format_block("edge_proxy_upstream_healthy", "gauge", "Upstream health check status (1=healthy, 0=unhealthy).", rows)
  end

  defp format_block(_name, _type, _help, []), do: ""

  defp format_block(name, type, help, rows) do
    Enum.join(
      [
        "# HELP #{name} #{help}",
        "# TYPE #{name} #{type}"
        | Enum.sort(rows)
      ],
      "\n"
    )
  end

  defp lookup_val(entries, key, default) do
    case List.keyfind(entries, key, 0) do
      {^key, val} -> val
      nil -> default
    end
  end

  defp escape(val) do
    val
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
