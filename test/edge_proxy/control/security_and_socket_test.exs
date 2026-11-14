defmodule EdgeProxy.Control.SecurityAndSocketTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias EdgeProxy.Control.{Plug, Security}
  alias EdgeProxy.Routing.Runtime

  setup do
    Application.put_env(:edge_proxy, :control_secret, "test_secret_key")
    Application.put_env(:edge_proxy, :allowed_control_tenants, ["tenant1"])

    on_exit(fn ->
      Application.delete_env(:edge_proxy, :allowed_control_tenants)
      Runtime.set_circuit_breaker("tenant1", :closed)
      Runtime.update([])
    end)

    :ok
  end

  defp sign_payload(payload) do
    sig = Security.sign(payload)
    Map.put(payload, "sig", sig)
  end

  test "accepts valid signed put_domain command and updates Runtime routes" do
    msg =
      sign_payload(%{
        "type" => "put_domain",
        "tenant" => "tenant1",
        "nonce" => "nonce-#{System.unique_integer([:positive])}",
        "ts" => System.system_time(:second),
        "domain" => "dynamic.mesh.local",
        "routes" => [
          %{
            "path" => "/api",
            "upstream" => %{"type" => "http", "host" => "127.0.0.1", "port" => 4099}
          }
        ]
      })

    conn =
      conn(:post, "/__edge_control__", Jason.encode!(msg))
      |> put_req_header("content-type", "application/json")
      |> Plug.call([])

    assert conn.status == 200
    assert Enum.any?(Runtime.routes(), &(&1.host == "dynamic.mesh.local"))
  end

  test "rejects replay of the same nonce" do
    nonce = "replay-nonce-#{System.unique_integer([:positive])}"

    msg =
      sign_payload(%{
        "type" => "noop",
        "tenant" => "tenant1",
        "nonce" => nonce,
        "ts" => System.system_time(:second)
      })

    body = Jason.encode!(msg)

    first =
      conn(:post, "/__edge_control__", body)
      |> put_req_header("content-type", "application/json")
      |> Plug.call([])

    second =
      conn(:post, "/__edge_control__", body)
      |> put_req_header("content-type", "application/json")
      |> Plug.call([])

    assert first.status == 200
    assert second.status == 401
    assert second.resp_body =~ "replay_detected"
  end

  test "rejects stale timestamps outside 30s window" do
    msg =
      sign_payload(%{
        "type" => "noop",
        "tenant" => "tenant1",
        "nonce" => "stale-#{System.unique_integer([:positive])}",
        "ts" => System.system_time(:second) - 120
      })

    assert {:error, :timestamp_out_of_range} = Security.verify(msg)
  end

  test "rejects tampered signatures and unauthorized tenants" do
    tampered =
      sign_payload(%{
        "type" => "noop",
        "tenant" => "tenant1",
        "ts" => System.system_time(:second)
      })
      |> Map.put("type", "delete_domain")

    assert {:error, :invalid_signature} = Security.verify(tampered)

    unauthorized =
      sign_payload(%{
        "type" => "noop",
        "tenant" => "evil_tenant",
        "ts" => System.system_time(:second)
      })

    assert {:error, :unauthorized_tenant} = Security.verify(unauthorized)
  end
end
