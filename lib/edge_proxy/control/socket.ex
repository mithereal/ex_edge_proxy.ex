defmodule EdgeProxy.Control.Socket do
  @moduledoc """
  Secure control-plane command processor.

  Responsibilities:
  - validate signed control messages
  - enforce replay protection
  - apply runtime updates (ETS mutation)
  - control tenant circuit breakers
  """

  use GenServer

  @nonce_table :edge_nonce

  # =========================================================
  # STARTUP
  # =========================================================

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    :ets.new(@nonce_table, [:named_table, :public, :set])
    {:ok, state}
  end

  # =========================================================
  # PUBLIC API (called by websocket handler)
  # =========================================================

  def handle_command(msg) when is_map(msg) do
    GenServer.call(__MODULE__, {:command, msg})
  end

  # =========================================================
  # GEN_SERVER CORE
  # =========================================================

  def handle_call({:command, msg}, _from, state) do
    with :ok <- EdgeProxy.Control.Security.verify(msg),
         :ok <- check_replay(msg),
         :ok <- apply_command(msg) do
      {:reply, :ok, state}
    else
      error ->
        {:reply, error, state}
    end
  end

  # =========================================================
  # COMMAND EXECUTION
  # =========================================================

  defp apply_command(%{"type" => "put_domain"} = msg) do
    EdgeProxy.Domain.Registry.put_domain(
      msg["domain"],
      msg["routes"]
    )

    :ok
  end

  defp apply_command(%{"type" => "put_wildcard"} = msg) do
    EdgeProxy.Domain.Registry.put_wildcard(
      msg["pattern"],
      msg["routes"]
    )

    :ok
  end

  defp apply_command(%{"type" => "delete_domain"} = msg) do
    :ets.delete(:edge_domains, msg["domain"])
    :ok
  end

  defp apply_command(%{"type" => "set_circuit_breaker"} = msg) do
    tenant = msg["tenant"]

    case msg["state"] do
      "open" ->
        EdgeProxy.Routing.Runtime.record_failure(tenant)

      "close" ->
        :ets.delete(:edge_cb, tenant)

      _ ->
        :ok
    end

    :ok
  end

  defp apply_command(%{"type" => "noop"}), do: :ok

  defp apply_command(_), do: {:error, :unknown_command}

  # =========================================================
  # REPLAY PROTECTION
  # =========================================================

  defp check_replay(%{"nonce" => nonce}) do
    case :ets.lookup(@nonce_table, nonce) do
      [] ->
        :ets.insert(@nonce_table, {nonce, System.system_time(:second)})
        :ok

      _ ->
        {:error, :replay_detected}
    end
  end

  defp check_replay(_), do: {:error, :missing_nonce}
end
