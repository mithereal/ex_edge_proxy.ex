defmodule EdgeProxy.Plug.InternalGuardTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias EdgeProxy.Plug.InternalGuard

  @opts InternalGuard.init([])

  test "allows standard public requests without backplane headers" do
    conn =
      conn(:get, "/api/v1/profile")
      |> Map.put(:host, "tenant1.auth.mesh.local")
      |> InternalGuard.call(@opts)

    refute conn.halted
  end

  test "blocks requests carrying x-backplane-service on public ingress" do
    conn =
      conn(:get, "/api/v1/verify")
      |> Map.put(:host, "auth.mesh.local")
      |> put_req_header("x-backplane-service", "payments.internal.mesh.local")
      |> InternalGuard.call(@opts)

    assert conn.halted
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"] == "forbidden"
  end

  test "blocks requests targeting *.internal.mesh.local" do
    conn =
      conn(:post, "/api/v1/capture")
      |> Map.put(:host, "payments.internal.mesh.local")
      |> InternalGuard.call(@opts)

    assert conn.halted
    assert conn.status == 403
  end

  test "supports custom internal_patterns option" do
    custom_opts = InternalGuard.init(internal_patterns: [~r/^private-.*\.mesh\.local$/i])

    conn =
      conn(:get, "/")
      |> Map.put(:host, "private-worker.mesh.local")
      |> InternalGuard.call(custom_opts)

    assert conn.halted
    assert conn.status == 403
  end
end
