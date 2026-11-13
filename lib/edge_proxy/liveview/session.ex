defmodule EdgeProxy.LiveView.Session do
  @moduledoc """
  Bidirectional WebSocket / LiveView proxy handler using WebSockAdapter & Mint.WebSocket.

  Responsibilities:
  - upgrade incoming client WebSocket connections
  - open upstream WebSocket handshake via Mint.WebSocket
  - relay frames bidirectionally with ordered flushing and bounded queue backpressure
  - enforce circuit breaker state per tenant
  """

  @behaviour WebSock
  require Logger

  alias EdgeProxy.Routing.Runtime

  @max_queue 200
  @flush_interval 5

  # ------------------------------------------------------------
  # UPGRADE ENTRYPOINT
  # ------------------------------------------------------------

  def upgrade(conn, route, _opts \\ []) do
    if Runtime.circuit_open?(route.tenant) do
      Plug.Conn.send_resp(conn, 503, "Service Unavailable (Circuit Open)")
    else
      state = %{
        upstream: route.upstream,
        tenant: route.tenant,
        path: request_path_with_query(conn),
        headers: forward_headers(conn),
        queue: :queue.new(),
        size: 0,
        mint_conn: nil,
        websocket: nil,
        req_ref: nil,
        flushing?: false
      }

      WebSockAdapter.upgrade(conn, __MODULE__, state, timeout: 60_000)
    end
  end

  # ------------------------------------------------------------
  # WEBSOCK CALLBACKS
  # ------------------------------------------------------------

  @impl true
  def init(state) do
    case connect_upstream(state) do
      {:ok, mint_conn, websocket, req_ref} ->
        {:ok, %{state | mint_conn: mint_conn, websocket: websocket, req_ref: req_ref}}

      {:error, reason} ->
        Logger.error("Upstream WebSocket handshake failed: #{inspect(reason)}")
        {:stop, :normal, {1011, "Upstream unavailable"}, state}
    end
  end

  @impl true
  def handle_in({data, [opcode: opcode]}, state) do
    cond do
      Runtime.circuit_open?(state.tenant) ->
        {:stop, :normal, {1011, "Circuit open"}, state}

      state.size >= @max_queue ->
        {:stop, :normal, {1008, "Backpressure limit exceeded"}, state}

      true ->
        frame = {opcode, data}
        queue = :queue.in(frame, state.queue)
        state = %{state | queue: queue, size: state.size + 1}
        state = if state.flushing?, do: state, else: schedule_flush(state)
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    case :queue.out(state.queue) do
      {{:value, frame}, rest} ->
        case send_upstream(state, frame) do
          {:ok, new_state} ->
            Process.send_after(self(), :flush, @flush_interval)
            {:ok, %{new_state | queue: rest, size: state.size - 1, flushing?: true}}

          {:error, reason, new_state} ->
            Logger.error("WebSocket upstream send error: #{inspect(reason)}")
            {:stop, :normal, {1011, "Upstream write error"}, new_state}
        end

      {:empty, _} ->
        {:ok, %{state | flushing?: false}}
    end
  end

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.mint_conn, message) do
      :unknown ->
        {:ok, state}

      {:ok, mint_conn, responses} ->
        state = %{state | mint_conn: mint_conn}
        handle_upstream_responses(responses, state)

      {:error, mint_conn, reason, _responses} ->
        Logger.error("WebSocket upstream stream error: #{inspect(reason)}")
        {:stop, :normal, {1011, "Upstream stream error"}, %{state | mint_conn: mint_conn}}
    end
  end

  @impl true
  def terminate(_reason, %{mint_conn: nil}), do: :ok

  def terminate(_reason, %{mint_conn: mint_conn}) do
    Mint.HTTP.close(mint_conn)
    :ok
  end

  # ------------------------------------------------------------
  # UPSTREAM HANDSHAKE & RELAY
  # ------------------------------------------------------------

  defp connect_upstream(%{upstream: upstream, path: path, headers: headers}) do
    ws_scheme = if upstream.scheme == :https, do: :wss, else: :ws

    with {:ok, mint_conn} <- Mint.HTTP.connect(upstream.scheme, upstream.host, upstream.port),
         {:ok, mint_conn, req_ref} <- Mint.WebSocket.upgrade(ws_scheme, mint_conn, path, headers),
         {:ok, mint_conn, status, resp_headers} <- await_upgrade_response(mint_conn, req_ref, nil, []),
         {:ok, mint_conn, websocket} <- Mint.WebSocket.new(mint_conn, req_ref, status, resp_headers) do
      {:ok, mint_conn, websocket, req_ref}
    end
  end

  defp await_upgrade_response(mint_conn, req_ref, status, headers) do
    receive do
      msg ->
        case Mint.WebSocket.stream(mint_conn, msg) do
          {:ok, mint_conn, responses} ->
            {status, headers, done?} =
              Enum.reduce(responses, {status, headers, false}, fn
                {:status, ^req_ref, s}, {_s, h, d} -> {s, h, d}
                {:headers, ^req_ref, h}, {s, acc_h, d} -> {s, acc_h ++ h, d}
                {:done, ^req_ref}, {s, h, _d} -> {s, h, true}
                _, acc -> acc
              end)

            if done? do
              {:ok, mint_conn, status, headers}
            else
              await_upgrade_response(mint_conn, req_ref, status, headers)
            end

          {:error, _mint_conn, reason, _responses} ->
            {:error, reason}

          :unknown ->
            await_upgrade_response(mint_conn, req_ref, status, headers)
        end
    after
      10_000 -> {:error, :ws_upgrade_timeout}
    end
  end

  defp handle_upstream_responses(responses, state) do
    Enum.reduce_while(responses, {:ok, [], state}, fn
      {:data, ref, data}, {:ok, frames, acc_state} when ref == acc_state.req_ref ->
        case Mint.WebSocket.decode(acc_state.websocket, data) do
          {:ok, websocket, decoded} ->
            client_frames =
              Enum.flat_map(decoded, fn
                {:text, text} -> [{:text, text}]
                {:binary, bin} -> [{:binary, bin}]
                {:ping, payload} -> [{:ping, payload}]
                {:pong, payload} -> [{:pong, payload}]
                {:close, _code, _reason} -> []
              end)

            {:cont, {:ok, frames ++ client_frames, %{acc_state | websocket: websocket}}}

          {:error, websocket, reason} ->
            {:halt, {:stop, :normal, {1002, inspect(reason)}, %{acc_state | websocket: websocket}}}
        end

      {:done, ref}, {:ok, _frames, acc_state} when ref == acc_state.req_ref ->
        {:halt, {:stop, :normal, {1000, "Upstream closed"}, acc_state}}

      _, acc ->
        {:cont, acc}
    end)
    |> case do
      {:ok, [], new_state} -> {:ok, new_state}
      {:ok, frames, new_state} -> {:push, frames, new_state}
      stop_tuple -> stop_tuple
    end
  end

  defp send_upstream(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, mint_conn} <- Mint.WebSocket.stream_request_body(state.mint_conn, state.req_ref, data) do
      {:ok, %{state | websocket: websocket, mint_conn: mint_conn}}
    else
      {:error, _ws_or_conn, reason} -> {:error, reason, state}
    end
  end

  defp schedule_flush(state) do
    Process.send_after(self(), :flush, 0)
    %{state | flushing?: true}
  end

  defp request_path_with_query(%{request_path: path, query_string: ""}), do: path
  defp request_path_with_query(%{request_path: path, query_string: qs}), do: "#{path}?#{qs}"

  defp forward_headers(conn) do
    Enum.filter(conn.req_headers, fn {k, _v} ->
      String.downcase(k) in [
        "x-edge-tenant",
        "x-edge-domain",
        "x-request-id",
        "cookie",
        "sec-websocket-protocol"
      ]
    end)
  end
end
