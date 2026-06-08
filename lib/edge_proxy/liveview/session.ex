defmodule EdgeProxy.LiveView.Session do
  @moduledoc """
  LiveView WebSocket session handler.

  Responsibilities:
  - manage client → upstream frame flow
  - enforce backpressure protection
  - guarantee ordered delivery
  - integrate with circuit breaker
  """

  use GenServer

  @max_queue 200
  @flush_interval 5

  # ------------------------------------------------------------
  # START
  # ------------------------------------------------------------

  def start(conn, route) do
    {:ok, pid} =
      GenServer.start(__MODULE__, %{
        client: conn,
        upstream: route.upstream,
        tenant: route.tenant,
        queue: :queue.new(),
        size: 0,
        upstream_conn: nil,
        flushing?: false
      })

    pid
  end

  # ------------------------------------------------------------
  # INIT
  # ------------------------------------------------------------

  def init(state) do
    if EdgeProxy.Routing.Runtime.circuit_open?(state.tenant) do
      {:stop, :circuit_open}
    else
      # In real system: establish Mint WS connection here
      state =
        state
        |> Map.put(:upstream_conn, :connected)

      {:ok, state}
    end
  end

  # ------------------------------------------------------------
  # CLIENT → PROXY
  # ------------------------------------------------------------

  def handle_info({:client_frame, frame}, state) do
    cond do
      EdgeProxy.Routing.Runtime.circuit_open?(state.tenant) ->
        {:stop, :circuit_open, state}

      state.size >= @max_queue ->
        {:stop, :backpressure, state}

      true ->
        queue = :queue.in(frame, state.queue)
        state = %{state | queue: queue, size: state.size + 1}

        state =
          if state.flushing? do
            state
          else
            schedule_flush(state)
          end

        {:noreply, state}
    end
  end

  # ------------------------------------------------------------
  # FLUSH LOOP (ORDERED DELIVERY)
  # ------------------------------------------------------------

  def handle_info(:flush, state) do
    case :queue.out(state.queue) do
      {{:value, frame}, rest} ->
        send_upstream(state.upstream_conn, frame)

        Process.send_after(self(), :flush, @flush_interval)

        {:noreply,
          %{state | queue: rest, size: state.size - 1, flushing?: true}}

      {:empty, _} ->
        {:noreply, %{state | flushing?: false}}
    end
  end

  # ------------------------------------------------------------
  # HELPERS
  # ------------------------------------------------------------

  defp schedule_flush(state) do
    Process.send_after(self(), :flush, 0)
    %{state | flushing?: true}
  end

  defp send_upstream({conn, websocket}, frame) do
    {:ok, websocket, data} =
      Mint.WebSocket.encode(websocket, frame)

    case Mint.HTTP.stream_request_body(conn, data) do
      :ok ->
        :ok

      {:error, conn, reason} ->
        exit({:upstream_send_failed, reason})
    end
  end
end