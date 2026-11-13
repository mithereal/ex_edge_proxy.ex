defmodule Mix.Tasks.EdgeProxy.Install do
  @shortdoc "Installs EdgeProxy across umbrella or Phoenix apps using Igniter"

  @moduledoc """
  Installs EdgeProxy into the edge gateway app and wires `EdgeContract`
  into downstream Phoenix apps.

  ## Usage

      mix edge_proxy.install
      mix edge_proxy.install edge
      mix edge_proxy.install apps
      mix edge_proxy.install uninstall
  """

  use Igniter.Mix.Task

  alias EdgeProxy.Igniter.Extension
  alias EdgeProxy.State

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :edge_proxy,
      positional: [mode: [optional: true]]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    case igniter.args.positional[:mode] do
      "edge" ->
        install_edge_app(igniter)

      "apps" ->
        install_phoenix_apps(igniter)

      "uninstall" ->
        uninstall_all(igniter)

      _ ->
        igniter
        |> install_edge_app()
        |> install_phoenix_apps()
    end
  end

  # ------------------------------------------------------------
  # EDGE APP ONLY (STRICT)
  # ------------------------------------------------------------

  defp install_edge_app(igniter) do
    case find_edge_endpoint() do
      nil ->
        Igniter.add_warning(
          igniter,
          "Could not find edge_proxy endpoint at apps/edge_proxy/lib/**/*endpoint.ex"
        )

      endpoint_path ->
        State.mark("edge_proxy", "endpoint", true)
        Extension.inject_edge_proxy_endpoint(igniter, endpoint_path)
    end
  end

  # ------------------------------------------------------------
  # PHOENIX APPS (CONTEXT ONLY)
  # ------------------------------------------------------------

  defp install_phoenix_apps(igniter) do
    Enum.reduce(phoenix_apps(), igniter, fn app_path, acc ->
      install_app(acc, app_path)
    end)
  end

  defp install_app(igniter, app_path) do
    State.mark(app_path, "installed", true)

    igniter
    |> install_endpoint(app_path)
    |> install_router(app_path)
    |> install_socket(app_path)
  end

  defp install_endpoint(igniter, app_path) do
    case find_file(app_path, "endpoint.ex") do
      nil ->
        Igniter.add_warning(igniter, "No endpoint.ex found in #{app_path}")

      file ->
        Extension.inject_edge_context_plug(igniter, file)
    end
  end

  defp install_router(igniter, app_path) do
    case find_file(app_path, "router.ex") do
      nil ->
        Igniter.add_warning(igniter, "No router.ex found in #{app_path}")

      file ->
        Extension.inject_liveview_hook(igniter, file)
    end
  end

  defp install_socket(igniter, app_path) do
    case find_file(app_path, "user_socket.ex") do
      nil ->
        igniter

      file ->
        Extension.inject_socket_context(igniter, file)
    end
  end

  # ------------------------------------------------------------
  # UNINSTALL
  # ------------------------------------------------------------

  defp uninstall_all(igniter) do
    igniter =
      Enum.reduce(phoenix_apps(), igniter, fn app_path, acc ->
        uninstall_app(acc, app_path)
      end)

    igniter = uninstall_edge_app(igniter)
    State.reset()
    igniter
  end

  defp uninstall_app(igniter, app_path) do
    case find_file(app_path, "endpoint.ex") do
      nil -> igniter
      file -> Extension.remove_edge_context_plug(igniter, file)
    end
  end

  defp uninstall_edge_app(igniter) do
    case find_edge_endpoint() do
      nil -> igniter
      file -> Extension.remove_edge_proxy_endpoint(igniter, file)
    end
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
    case File.read(mixfile) do
      {:ok, content} -> Regex.match?(~r/\{:phoenix\b/, content)
      _ -> false
    end
  end

  defp find_edge_endpoint do
    Path.wildcard("apps/edge_proxy/lib/**/*endpoint.ex")
    |> List.first()
  end

  defp find_file(app_path, suffix) do
    Path.join(app_path, "lib/**/*#{suffix}")
    |> Path.wildcard()
    |> List.first()
  end
end
