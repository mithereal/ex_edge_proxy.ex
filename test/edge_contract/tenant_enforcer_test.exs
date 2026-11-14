defmodule EdgeContract.TenantEnforcerTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias EdgeContract.TenantEnforcer
  alias EdgeProxy.EdgeContract

  defmodule MockRepo do
    def put_tenant(tenant) do
      Process.put(:mock_ecto_tenant, tenant)
      :ok
    end
  end

  setup do
    Process.delete(:mock_ecto_tenant)
    Process.delete(:mock_ash_tenant)

    Application.put_env(:edge_proxy, :enable_ecto_tenant, true)
    Application.put_env(:edge_proxy, :ecto_repo, MockRepo)
    Application.put_env(:edge_proxy, :enable_ash_tenant, true)

    unless Code.ensure_loaded?(Ash) do
      defmodule Ash do
        def set_tenant(tenant) do
          Process.put(:mock_ash_tenant, tenant)
          :ok
        end
      end
    end

    on_exit(fn ->
      Application.delete_env(:edge_proxy, :enable_ecto_tenant)
      Application.delete_env(:edge_proxy, :ecto_repo)
      Application.delete_env(:edge_proxy, :enable_ash_tenant)
    end)

    :ok
  end

  test "applies Ecto and Ash tenant context when tenant is present" do
    contract = %EdgeContract{tenant: "acme_corp", domain: "acme.mesh.local"}
    assert :ok = TenantEnforcer.apply(contract)

    assert Process.get(:mock_ecto_tenant) == "acme_corp"
    assert Process.get(:mock_ash_tenant) == "acme_corp"
  end

  test "does nothing when tenant is nil or empty" do
    assert :ok = TenantEnforcer.apply(%EdgeContract{tenant: nil})
    assert :ok = TenantEnforcer.apply(%EdgeContract{tenant: ""})

    assert Process.get(:mock_ecto_tenant) == nil
    assert Process.get(:mock_ash_tenant) == nil
  end

  test "EdgeContract.Plug automatically triggers TenantEnforcer on incoming HTTP requests" do
    conn =
      conn(:get, "/orders")
      |> put_req_header("x-edge-tenant", "tenant_42")
      |> EdgeContract.Plug.call([])

    assert conn.assigns.edge.tenant == "tenant_42"
    assert Process.get(:mock_ecto_tenant) == "tenant_42"
    assert Process.get(:mock_ash_tenant) == "tenant_42"
  end

  test "EdgeContract.LiveView automatically triggers TenantEnforcer on mount" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
    session = %{"edge_contract" => %{"tenant" => "tenant_99"}}

    assert {:cont, _socket} =
             EdgeContract.LiveView.on_mount(:require_tenant, %{}, session, socket)

    assert Process.get(:mock_ecto_tenant) == "tenant_99"
    assert Process.get(:mock_ash_tenant) == "tenant_99"
  end
end
