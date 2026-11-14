defmodule EdgeProxy.BackplaneClientTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias EdgeProxy.BackplaneClient

  defmodule TestMeshPlug do
    use Plug.Router

    plug :match
    plug :dispatch

    get "/api/v1/verify" do
      payload = %{
        backplane_service: get_header(conn, "x-backplane-service"),
        tenant: get_header(conn, "x-edge-tenant"),
        domain: get_header(conn, "x-edge-domain"),
        request_id: get_header(conn, "x-request-id"),
        auth: get_header(conn, "authorization")
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(payload))
    end

    post "/api/v1/charges" do
      {:ok, raw, conn} = read_body(conn)

      payload = %{
        received_body: Jason.decode!(raw),
        tenant: get_header(conn, "x-edge-tenant"),
        backplane_service: get_header(conn, "x-backplane-service")
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, Jason.encode!(payload))
    end

    get "/unavailable" do
      send_resp(conn, 502, "Bad Gateway")
    end

    defp get_header(conn, key) do
      case Plug.Conn.get_req_header(conn, key) do
        [val | _] -> val
        _ -> nil
      end
    end
  end

  setup do
    {:ok, server_pid} =
      Bandit.start_link(
        plug: TestMeshPlug,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)
    mesh_url = "http://127.0.0.1:#{port}"

    on_exit(fn ->
      if Process.alive?(server_pid), do: GenServer.stop(server_pid)
    end)

    %{mesh_url: mesh_url}
  end

  test "injects x-backplane-service and forwards EdgeContract headers from Plug.Conn", %{
    mesh_url: mesh_url
  } do
    incoming_conn =
      conn(:get, "/checkout")
      |> put_req_header("x-edge-tenant", "acme-corp")
      |> put_req_header("x-edge-domain", "acme.mesh.local")
      |> put_req_header("x-request-id", "req-999")

    assert {:ok, %{status: 200, body: body}} =
             BackplaneClient.request("auth.mesh.local", "/api/v1/verify",
               mesh_url: mesh_url,
               conn: incoming_conn,
               headers: [{"authorization", "Bearer tok_123"}]
             )

    decoded = Jason.decode!(body)
    assert decoded["backplane_service"] == "auth.mesh.local"
    assert decoded["tenant"] == "acme-corp"
    assert decoded["domain"] == "acme.mesh.local"
    assert decoded["request_id"] == "req-999"
    assert decoded["auth"] == "Bearer tok_123"
  end

  test "encodes JSON payloads and explicit tenant option", %{mesh_url: mesh_url} do
    assert {:ok, %{status: 201, body: body}} =
             BackplaneClient.request("billing.internal.mesh.local", "/api/v1/charges",
               mesh_url: mesh_url,
               method: :post,
               tenant: "tenant-42",
               json: %{amount: 5000, currency: "USD"}
             )

    decoded = Jason.decode!(body)
    assert decoded["backplane_service"] == "billing.internal.mesh.local"
    assert decoded["tenant"] == "tenant-42"
    assert decoded["received_body"] == %{"amount" => 5000, "currency" => "USD"}
  end

  test "normalizes 502 responses into {:error, {:service_unavailable, resp}}", %{
    mesh_url: mesh_url
  } do
    assert {:error, {:service_unavailable, %{status: 502}}} =
             BackplaneClient.request("missing.mesh.local", "/unavailable", mesh_url: mesh_url)
  end

  test "returns {:error, {:transport_error, _}} when mesh backplane is unreachable" do
    assert {:error, {:transport_error, _reason}} =
             BackplaneClient.request("auth.mesh.local", "/api/v1/verify",
               mesh_url: "http://127.0.0.1:59999"
             )
  end
end
