defmodule EdgeProxy.Control.Socket do
  @moduledoc """
  Secure control-plane command processor with periodic nonce eviction.
  """

  use GenServer

  @nonce_table :edge_nonce
  @nonce_ttl 60
  @cleanup_interval 30_000

  # ------------------------------------------------------------
  # STARTUP & PUBLIC API
  # ------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def handle_command(msg) when is_map(msg) do
    GenServer.call(__MODULE__, {:command, msg})
  end

  # ------------------------------------------------------------
  # GEN_SERVER CALLBACKS
  # ------------------------------------------------------------

  @impl true
  def init(state) do
    :ets.new(@nonce_table, [:named_table, :public, :set])
    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_call({:command, msg}, _from, state) do
    with :ok <- EdgeProxy.Control.Security.verify(msg),
         :ok <- check_replay(msg),
         :ok <- apply_command(msg) do
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:cleanup_nonces, state) do
    cutoff = System.system_time(:second) - @nonce_ttl

    :ets.select_delete(@nonce_table, [
      {{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  # ------------------------------------------------------------
  # COMMAND EXECUTION
  # ------------------------------------------------------------

  defp apply_command(%{"type" => "put_domain", "domain" => domain, "routes" => routes})
       when is_binary(domain) and is_list(routes) do
    EdgeProxy.Routing.Runtime.put_domain(domain, routes)
  end

  defp apply_command(%{"type" => "put_wildcard", "pattern" => pattern, "routes" => routes})
       when is_binary(pattern) and is_list(routes) do
    EdgeProxy.Routing.Runtime.put_wildcard(pattern, routes)
  end

  defp apply_command(%{"type" => "delete_domain", "domain" => domain}) when is_binary(domain) do
    EdgeProxy.Routing.Runtime.delete_domain(domain)
  end

  defp apply_command(%{"type" => "set_circuit_breaker", "tenant" => tenant, "state" => cb_state})
       when is_binary(tenant) do
    case cb_state do
      "open" ->
        EdgeProxy.Routing.Runtime.set_circuit_breaker(tenant, :open)
        :ok

      "close" ->
        EdgeProxy.Routing.Runtime.set_circuit_breaker(tenant, :closed)
        :ok

      _ ->
        {:error, :invalid_circuit_state}
    end
  end

  defp apply_command(%{"type" => "noop"}), do: :ok
  defp apply_command(_), do: {:error, :unknown_command}

  # ------------------------------------------------------------
  # REPLAY PROTECTION
  # ------------------------------------------------------------

  defp check_replay(%{"nonce" => nonce}) when is_binary(nonce) and nonce != "" do
    now = System.system_time(:second)

    if :ets.insert_new(@nonce_table, {nonce, now}) do
      :ok
    else
      {:error, :replay_detected}
    end
  end

  defp check_replay(_), do: {:error, :missing_nonce}

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_nonces, @cleanup_interval)
  end
end
