defmodule EdgeProxy.Control.ClientTest do
  use ExUnit.Case, async: false

  alias EdgeProxy.Control.Client
  alias EdgeProxy.Routing.Runtime

  setup do
    port = 4095
    url = "http://127.0.0.1:#{port}/__edge_control__"

    {:ok, _} =
      start_supervised(
        {Bandit, plug: EdgeProxy.Control.Plug, port: port, startup_log: false},
        id: :control_client_test_server
      )

    on_exit(fn ->
      Runtime.set_circuit_breaker("tenant_cli", :closed)
      Runtime.update([])
    end)

    {:ok, url: url}
  end

  test "sends signed ping, put_domain, circuit breaker, and delete_domain over HTTP", %{url: url} do
    assert :ok = Client.ping(url: url)

    route = %{path: "/v1", upstream: %{type: "http", host: "127.0.0.1", port: 4050}}
    assert :ok = Client.put_domain("api.mesh.local", [route], url: url)
    assert Enum.any?(Runtime.routes(), &(&1.host == "api.mesh.local"))

    assert :ok = Client.set_circuit_breaker("tenant_cli", :open, url: url)
    :sys.get_state(Runtime)
    assert Runtime.circuit_open?("tenant_cli")

    assert :ok = Client.set_circuit_breaker("tenant_cli", :closed, url: url)
    :sys.get_state(Runtime)
    refute Runtime.circuit_open?("tenant_cli")

    assert :ok = Client.delete_domain("api.mesh.local", url: url)
    refute Enum.any?(Runtime.routes(), &(&1.host == "api.mesh.local"))
  end

  test "returns {:error, {:http_error, 401, _}} when signing secret mismatches", %{url: url} do
    assert {:error, {:http_error, 401, %{"status" => "error"}}} =
             Client.ping(url: url, secret: "wrong_secret")
  end
end
