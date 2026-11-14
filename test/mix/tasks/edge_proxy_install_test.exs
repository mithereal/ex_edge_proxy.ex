defmodule Mix.Tasks.EdgeProxy.InstallTest do
  use ExUnit.Case, async: false
  import Igniter.Test

  setup do
    on_exit(fn ->
      EdgeProxy.State.reset()
    end)

    :ok
  end

  test "scaffolds gateway app and routes.json when --generate-gateway is passed" do
    test_project(
      files: %{
        "apps/billing_app/mix.exs" => """
        defmodule BillingApp.MixProject do
          use Mix.Project
          def project, do: [app: :billing_app, deps: [{:phoenix, "~> 1.7"}]]
        end
        """,
        "apps/billing_app/lib/billing_app_web/endpoint.ex" => """
        defmodule BillingAppWeb.Endpoint do
          use Phoenix.Endpoint, otp_app: :billing_app
        end
        """,
        "apps/billing_app/lib/billing_app_web/router.ex" => """
        defmodule BillingAppWeb.Router do
          use Phoenix.Router
        end
        """
      }
    )
    |> Igniter.compose_task("edge_proxy.install", ["--generate-gateway", "--port", "4050"])
    |> assert_creates("apps/gateway/mix.exs", fn content ->
      assert content =~ "app: :gateway"
      assert content =~ "{:edge_proxy"
      assert content =~ "{:bandit"
    end)
    |> assert_creates("apps/gateway/lib/gateway/application.ex", fn content ->
      assert content =~ "defmodule Gateway.Application"
      assert content =~ ~s(System.get_env("GATEWAY_PORT") || "4050")
    end)
    |> assert_creates("apps/gateway/lib/gateway/endpoint.ex", fn content ->
      assert content =~ "defmodule Gateway.Endpoint"
      assert content =~ "plug EdgeProxy.Control.Plug"
      assert content =~ "plug EdgeProxy.Plug.Router"
      refute content =~ "plug EdgeProxy.Metrics.Plug"
    end)
    |> assert_creates("edge_proxy/routes.json", fn content ->
      assert {:ok, routes} = Jason.decode(content)
      assert is_list(routes)
    end)
    |> assert_has_patch("apps/billing_app/lib/billing_app_web/endpoint.ex", """
    + |  plug EdgeContract.Plug
    """)
    |> assert_has_patch("apps/billing_app/lib/billing_app_web/router.ex", """
    + |  on_mount {EdgeContract.LiveView, :default}
    """)
  end

  test "mounts EdgeProxy.Metrics.Plug when --telemetry flag is passed" do
    test_project()
    |> Igniter.compose_task("edge_proxy.install", [
      "--generate-gateway",
      "--gateway-app",
      "edge_gw",
      "--telemetry"
    ])
    |> assert_creates("apps/edge_gw/lib/edge_gw/endpoint.ex", fn content ->
      assert content =~ "defmodule EdgeGw.Endpoint"
      assert content =~ "plug EdgeProxy.Metrics.Plug"
      assert content =~ "plug EdgeProxy.Control.Plug"
      assert content =~ "plug EdgeProxy.Plug.Router"
    end)
  end

  test "injects EdgeProxy.Metrics.Plug into an existing gateway endpoint with edge --telemetry" do
    test_project(
      files: %{
        "apps/gateway/mix.exs" => """
        defmodule Gateway.MixProject do
          use Mix.Project
          def project, do: [app: :gateway, deps: [{:edge_proxy, path: "../ex_edge_proxy"}]]
        end
        """,
        "apps/gateway/lib/gateway/endpoint.ex" => """
        defmodule Gateway.Endpoint do
          use Phoenix.Endpoint, otp_app: :gateway
          plug EdgeProxy.Plug.Router
        end
        """
      }
    )
    |> Igniter.compose_task("edge_proxy.install", ["edge", "--telemetry"])
    |> assert_has_patch("apps/gateway/lib/gateway/endpoint.ex", """
    + |  plug EdgeProxy.Metrics.Plug
    """)
  end

  test "uninstall removes EdgeContract and EdgeProxy plugs cleanly" do
    test_project(
      files: %{
        "apps/edge_proxy/lib/edge_proxy_web/endpoint.ex" => """
        defmodule EdgeProxyWeb.Endpoint do
          use Phoenix.Endpoint, otp_app: :edge_proxy
          plug EdgeProxy.Metrics.Plug
          plug EdgeProxy.Plug.Router
        end
        """,
        "apps/auth_app/mix.exs" => """
        defmodule AuthApp.MixProject do
          use Mix.Project
          def project, do: [app: :auth_app, deps: [{:phoenix, "~> 1.7"}]]
        end
        """,
        "apps/auth_app/lib/auth_app_web/endpoint.ex" => """
        defmodule AuthAppWeb.Endpoint do
          use Phoenix.Endpoint, otp_app: :auth_app
          plug EdgeContract.Plug
        end
        """
      }
    )
    |> Igniter.compose_task("edge_proxy.install", ["uninstall"])
    |> assert_has_patch("apps/edge_proxy/lib/edge_proxy_web/endpoint.ex", """
    - |  plug EdgeProxy.Metrics.Plug
    - |  plug EdgeProxy.Plug.Router
    """)
    |> assert_has_patch("apps/auth_app/lib/auth_app_web/endpoint.ex", """
    - |  plug EdgeContract.Plug
    """)
  end
end
