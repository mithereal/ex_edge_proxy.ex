defmodule EdgeProxy.HTTP.ForwarderTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias EdgeProxy.Routing.Runtime

  defmodule MockUpstreamPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      tenant = get_req_header(conn, "x-edge-tenant") |> List.first()

      conn

      |> put_resp_header("x-upstream-tenant", tenant || "none")
      |> send_resp(201, "echo:#{conn.request_path}?#{conn.query_string}:#{body}")
    end
  end

  setup do
    port = 4098
    {:ok, _pid} = start_supervised({Bandit, plug: MockUpstreamPlug, port: port, startup_log: false})

    Runtime.update([
      %{
        tenant: "tenant1",
        host: "proxy.mesh.local",
        path: "/items",
        upstream: {:http, "127.0.0.1", port}
      }
    ])

    :sys.get_state(Runtime)

    on_exit(fn -> Runtime.update([]) end)
    :ok
  end

  test "forwards HTTP POST request, query params, and EdgeContract headers to upstream" do
    conn =
      conn(:post, "http://mesh.local", "payload=123")
      |> put_req_header("x-edge-tenant", "tenant1")
      |> EdgeProxy.call([])

    assert conn.status == 201
    assert get_resp_header(conn, "x-upstream-tenant") == ["tenant1"]
    assert conn.resp_body == "echo:/items?filter=active:payload=123"
  end
end
