defmodule EdgeProxy.LiveView.SessionTest do
  use ExUnit.Case, async: false

  alias EdgeProxy.Routing.Runtime

  defmodule UpstreamEchoSocket do
    @behaviour WebSock

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_in({text, [opcode: :text]}, state) do
      {:push, [{:text, "upstream_echo:#{text}"}], state}
    end

    def handle_in(_frame, state), do: {:ok, state}

    @impl true
    def handle_info(_msg, state), do: {:ok, state}
  end

  defmodule UpstreamRouter do
    use Plug.Router

    plug :match
    plug :dispatch

    get "/live/websocket" do
      tenant = Plug.Conn.get_req_header(conn, "x-edge-tenant") |> List.first()
      WebSockAdapter.upgrade(conn, UpstreamEchoSocket, %{tenant: tenant}, timeout: 10_000)
    end
  end

  setup do
    upstream_port = 4096
    gateway_port = 4097

    {:ok, _} =
      start_supervised(
        {Bandit, plug: UpstreamRouter, port: upstream_port, startup_log: false},
        id: :mock_ws_upstream
      )

    {:ok, _} =
      start_supervised(
        {Bandit, plug: EdgeProxy.Plug.Router, port: gateway_port, startup_log: false},
        id: :mock_ws_gateway
      )

    Runtime.update([
      %{
        tenant: "tenant1",
        host: "ws.mesh.local",
        path: "/live/websocket",
        upstream: {:http, "127.0.0.1", upstream_port}
      }
    ])

    :sys.get_state(Runtime)

    on_exit(fn ->
      Runtime.set_circuit_breaker("tenant1", :closed)
      Runtime.update([])
    end)

    {:ok, gateway_port: gateway_port}
  end

  test "relays WebSocket text frames bidirectionally through EdgeProxy", %{gateway_port: port} do
    headers = [
      {"host", "ws.mesh.local"},
      {"x-edge-tenant", "tenant1"}
    ]

    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/live/websocket", headers)

    {:ok, conn, status, resp_headers} = receive_upgrade(conn, ref, nil, [])
    assert status == 101

    {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, resp_headers)
    {:ok, ws, data} = Mint.WebSocket.encode(ws, {:text, "hello_liveview"})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    assert {:ok, conn, _ws, [{:text, "upstream_echo:hello_liveview"}]} =
             receive_frame(conn, ws, ref)

    Mint.HTTP.close(conn)
  end

  test "rejects WebSocket upgrade with 503 when circuit breaker is open", %{gateway_port: port} do
    Runtime.set_circuit_breaker("tenant1", :open)
    :sys.get_state(Runtime)

    headers = [
      {"host", "ws.mesh.local"},
      {"x-edge-tenant", "tenant1"}
    ]

    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/live/websocket", headers)

    assert {:ok, conn, 503, _headers} = receive_upgrade(conn, ref, nil, [])
    Mint.HTTP.close(conn)
  end

  defp receive_upgrade(conn, ref, status, headers) do
    receive do
      msg ->
        case Mint.WebSocket.stream(conn, msg) do
          {:ok, conn, responses} ->
            {status, headers, done?} =
              Enum.reduce(responses, {status, headers, false}, fn
                {:status, ^ref, s}, {_s, h, d} -> {s, h, d}
                {:headers, ^ref, h}, {s, acc_h, d} -> {s, acc_h ++ h, d}
                {:done, ^ref}, {s, h, _d} -> {s, h, true}
                _, acc -> acc
              end)

            if done?, do: {:ok, conn, status, headers}, else: receive_upgrade(conn, ref, status, headers)

          :unknown ->
            receive_upgrade(conn, ref, status, headers)
        end
    after
      5_000 -> flunk("Timed out waiting for WebSocket upgrade")
    end
  end

  defp receive_frame(conn, ws, ref) do
    receive do
      msg ->
        case Mint.WebSocket.stream(conn, msg) do
          {:ok, conn, [{:data, ^ref, data} | _]} ->
            {:ok, ws, frames} = Mint.WebSocket.decode(ws, data)
            {:ok, conn, ws, frames}

          {:ok, conn, _other} ->
            receive_frame(conn, ws, ref)

          :unknown ->
            receive_frame(conn, ws, ref)
        end
    after
      5_000 -> flunk("Timed out waiting for WebSocket frame")
    end
  end
end
