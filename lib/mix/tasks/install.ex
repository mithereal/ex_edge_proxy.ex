defmodule Mix.Tasks.EdgeProxy.Install do
  use Mix.Task

  @shortdoc "Installs EdgeProxy correctly across umbrella (strict boundary mode)"

  alias EdgeProxy.Igniter.Extension
  alias EdgeProxy.State

  @impl true
  def run(args) do
    case args do
      ["edge"] -> install_edge_app()
      ["apps"] -> install_phoenix_apps()
      ["uninstall"] -> uninstall_all()
      _ -> install_all()
    end
  end

  # ------------------------------------------------------------
  # FULL INSTALL
  # ------------------------------------------------------------

  defp install_all do
    install_edge_app()
    install_phoenix_apps()
  end

  # ------------------------------------------------------------
  # EDGE APP ONLY (STRICT)
  # ------------------------------------------------------------

  defp install_edge_app do
    Mix.shell().info("🔐 Installing EdgeProxy (edge app only)")

    endpoint = find_edge_endpoint()

    endpoint
    |> Igniter.read_file()
    |> Extension.inject_edge_proxy_endpoint()
    |> Igniter.write_file(endpoint)

    State.mark("edge_proxy", "endpoint", true)

    Mix.shell().info("✅ EdgeProxy installed in edge app")
  end

  # ------------------------------------------------------------
  # PHOENIX APPS (CONTEXT ONLY)
  # ------------------------------------------------------------

  defp install_phoenix_apps do
    Mix.shell().info("📦 Installing EdgeContract into Phoenix apps")

    phoenix_apps()
    |> Enum.each(fn app ->
      install_app(app)
    end)
  end

  defp install_app(app) do
    install_endpoint(app)
    install_router(app)
    install_socket(app)

    State.mark(app, "installed", true)
  end

  defp install_endpoint(app) do
    file = find_file(app, "endpoint.ex")

    file
    |> Igniter.read_file()
    |> Extension.inject_edge_context_plug()
    |> Igniter.write_file(file)
  end

  defp install_router(app) do
    file = find_file(app, "router.ex")

    file
    |> Igniter.read_file()
    |> Extension.inject_liveview_hook()
    |> Igniter.write_file(file)
  end

  defp install_socket(app) do
    case find_optional_file(app, "user_socket.ex") do
      nil ->
        :ok

      file ->
        file
        |> Igniter.read_file()
        |> Extension.inject_socket_context()
        |> Igniter.write_file(file)
    end
  end

  # ------------------------------------------------------------
  # EDGE UNINSTALL
  # ------------------------------------------------------------

  defp uninstall_all do
    Mix.shell().info("🧹 Uninstalling EdgeProxy from umbrella")

    phoenix_apps()
    |> Enum.each(&uninstall_app/1)

    uninstall_edge_app()

    State.reset()
  end

  defp uninstall_app(app) do
    file = find_file(app, "endpoint.ex")

    file
    |> Igniter.read_file()
    |> Extension.remove_edge_context_plug()
    |> Igniter.write_file(file)

    Mix.shell().info("↩ removed EdgeContract from #{app}")
  end

  defp uninstall_edge_app do
    file = find_edge_endpoint()

    file
    |> Igniter.read_file()
    |> Extension.remove_edge_proxy_endpoint()
    |> Igniter.write_file(file)

    Mix.shell().info("↩ removed EdgeProxy endpoint wiring")
  end

  # ------------------------------------------------------------
  # DISCOVERY
  # ------------------------------------------------------------

  defp phoenix_apps do
    Path.wildcard("apps/*/mix.exs")
    |> Enum.reject(&String.contains?(&1, "edge_proxy"))
    |> Enum.filter(&phoenix_app?/1)
    |> Enum.map(&Path.dirname/1)
  end

  defp phoenix_app?(mixfile) do
    mixfile |> File.read!() |> String.contains?(":phoenix")
  end

  defp find_edge_endpoint do
    Path.wildcard("apps/edge_proxy/lib/**/*endpoint.ex")
    |> List.first()
  end

  defp find_file(app, file) do
    Path.join(app, "lib/**/*#{file}")
    |> Path.wildcard()
    |> List.first()
  end

  defp find_optional_file(app, file) do
    Path.join(app, "lib/**/*#{file}")
    |> Path.wildcard()
    |> List.first()
  end
end