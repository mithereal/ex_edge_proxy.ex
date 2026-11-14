defmodule EdgeProxy.RateLimiter do
  @moduledoc """
  Lock-free, ETS-backed fixed-window per-tenant rate limiter.

  Config options (under `:edge_proxy, :rate_limit`):
  - `enabled: true | false` (default: `false`)
  - `max_requests: integer()` (default: `100`)
  - `window_seconds: integer()` (default: `60`)
  - `tenant_overrides: %{String.t() => integer()}` (default: `%{}`)
  """

  use GenServer

  @table :edge_proxy_rate_limits
  @cleanup_interval 60_000

  # ------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------

  @doc """
  Checks and increments the request counter for `tenant`.

  Returns:
  - `:ok` when rate limiting is disabled, `tenant` is nil, or within quota
  - `{:error, :rate_limited, retry_after_seconds}` when quota is exceeded
  """
  def check(nil), do: :ok

  def check(tenant) when is_binary(tenant) do
    cfg = config()

    if Keyword.get(cfg, :enabled, false) do
      window_sec = Keyword.get(cfg, :window_seconds, 60)
      limit = limit_for(tenant, cfg)
      now = System.system_time(:second)
      bucket = div(now, window_sec)
      key = {tenant, bucket}

      count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

      if count <= limit do
        :ok
      else
        retry_after = (bucket + 1) * window_sec - now
        {:error, :rate_limited, max(retry_after, 1)}
      end
    else
      :ok
    end
  end

  @doc """
  Resets all rate limit counters (useful in tests or admin overrides).
  """
  def reset do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  # ------------------------------------------------------------
  # GEN_SERVER (TABLE OWNER & GC)
  # ------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    window_sec = Keyword.get(config(), :window_seconds, 60)
    current_bucket = div(System.system_time(:second), window_sec)

    :ets.select_delete(@table, [
      {{{:"$1", :"$2"}, :_}, [{:<, :"$2", current_bucket}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp limit_for(tenant, cfg) do
    overrides = Keyword.get(cfg, :tenant_overrides, %{})
    Map.get(overrides, tenant, Keyword.get(cfg, :max_requests, 100))
  end

  defp config do
    Application.get_env(:edge_proxy, :rate_limit, [])
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
