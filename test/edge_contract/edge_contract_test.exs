defmodule EdgeContract.EdgeContractTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias EdgeProxy.EdgeContract

  test "EdgeContract.Plug populates conn.assigns.edge from headers" do
    auth_json = Jason.encode!(%{"user_id" => 42}) |> Base.url_encode64(padding: false)

    conn =
      conn(:get, "/dashboard")
      |> put_req_header("x-edge-tenant", "tenant1")
      |> put_req_header("x-edge-domain", "tenant1.app.local")
      |> put_req_header("x-request-id", "req-123")
      |> put_req_header("x-edge-auth", auth_json)
      |> EdgeContract.Plug.call([])

    assert %EdgeContract{
             tenant: "tenant1",
             domain: "tenant1.app.local",
             request_id: "req-123",
             auth_context: %{"user_id" => 42}
           } = conn.assigns.edge
  end

  test "EdgeContract.LiveView restores contract from session and enforces require_tenant" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    session = %{
      "edge_contract" => %{
        "tenant" => "tenant1",
        "domain" => "tenant1.app.local",
        "request_id" => "req-999"
      }
    }

    assert {:cont, updated_socket} =
             EdgeContract.LiveView.on_mount(:require_tenant, %{}, session, socket)

    assert updated_socket.assigns.edge.tenant == "tenant1"

    assert {:halt, _redirected_socket} =
             EdgeContract.LiveView.on_mount(:require_tenant, %{}, %{}, socket)
  end
end
