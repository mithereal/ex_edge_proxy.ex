defmodule Mix.Tasks.EdgeProxy.Install do
  @shortdoc "Installs EdgeProxy across umbrella or Phoenix apps using Igniter"

  @moduledoc """
  Installs EdgeProxy into an edge gateway app and wires `EdgeContract`
  into downstream Phoenix apps.

  ## Usage

      mix edge_proxy.install
      mix edge_proxy.install --generate-gateway
      mix edge_proxy.install --generate-gateway --telemetry
      mix edge_proxy.install --generate-gateway --gateway-app edge_gateway --port 8080 --telemetry
      mix edge_proxy.install edge --telemetry
      mix edge_proxy.install apps
      mix edge_proxy.install uninstall
      mix edge_proxy.install uninstall --remove-gateway
  """

  use Igniter.Mix.Task

  alias EdgeProxy.Igniter.Extension
  alias EdgeProxy.State

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :edge_proxy,
      positional: [mode: [optional: true]],
      schema: [
        generate_gateway: :boolean,
        gateway_app: :string,
        port: :integer,
        telemetry: :boolean,
        remove_gateway: :boolean
      ],
      defaults: [
        generate_gateway: false,
        gateway_app: "gateway",
        port: 4000,
        telemetry: false,
        remove_gateway: false
      ]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    opts = igniter.args.options

    case igniter.args.positional[:mode] do
      "edge" ->
        install_edge_app(igniter, opts)

      "apps" ->
        install_phoenix_apps(igniter)

      "uninstall" ->
        uninstall_all(igniter, opts)

      _ ->
        igniter
        |> install_edge_app(opts)
        |> install_phoenix_apps()
    end
  end

  # ------------------------------------------------------------
  # EDGE GATEWAY APP (SCAFFOLD OR WIRE EXISTING)
  # ------------------------------------------------------------

  defp install_edge_app(igniter, opts) do
    gateway_app = opts[:gateway_app] || "gateway"

    case find_edge_endpoint(gateway_app) do
      nil ->
        if opts[:generate_gateway] do
          scaffold_gateway_app(igniter, opts)
        else
          Igniter.add_warning(
            igniter,
            "No gateway endpoint found at apps/#{gateway_app}/lib/**/*endpoint.ex. " <>
              "Pass `--generate-gateway` to scaffold apps/#{gateway_app} automatically."
          )
        end

      endpoint_path ->
        State.mark(gateway_app, "endpoint", true)

        igniter = Extension.inject_edge_proxy_endpoint(igniter, endpoint_path)

        if opts[:telemetry] do
          Extension.inject_metrics_plug(igniter, endpoint_path)
        else
          igniter
        end
    end
  end

  defp scaffold_gateway_app(igniter, opts) do
    app_name = opts[:gateway_app] || "gateway"
    port = opts[:port] || 4000
    telemetry? = opts[:telemetry] || false
    mod_name = Macro.camelize(app_name)

    State.mark(app_name, "generated", true)
    State.mark(app_name, "endpoint", true)

    igniter
    |> Igniter.create_new_file("apps/#{app_name}/mix.exs", gateway_mix_template(app_name, mod_name))
    |> Igniter.create_new_file(
      "apps/#{app_name}/lib/#{app_name}/application.ex",
      gateway_app_template(mod_name, port)
    )
    |> Igniter.create_new_file(
      "apps/#{app_name}/lib/#{app_name}/endpoint.ex",
      gateway_endpoint_template(mod_name, telemetry?)
    )
    |> maybe_create_routes_json()
  end

  defp maybe_create_routes_json(igniter) do
    if Igniter.exists?(igniter, "edge_proxy/routes.json") do
      igniter
    else
      Igniter.create_new_file(igniter, "edge_proxy/routes.json", default_routes_json())
    end
  end

  # ------------------------------------------------------------
  # DOWNSTREAM PHOENIX APPS (CONTEXT ONLY)
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
      nil -> Igniter.add_warning(igniter, "No endpoint.ex found in #{app_path}")
      file -> Extension.inject_edge_context_plug(igniter, file)
    end
  end

  defp install_router(igniter, app_path) do
    case find_file(app_path, "router.ex") do
      nil -> Igniter.add_warning(igniter, "No router.ex found in #{app_path}")
      file -> Extension.inject_liveview_hook(igniter, file)
    end
  end

  defp install_socket(igniter, app_path) do
    case find_file(app_path, "user_socket.ex") do
      nil -> igniter
      file -> Extension.inject_socket_context(igniter, file)
    end
  end

  # ------------------------------------------------------------
  # UNINSTALL
  # ------------------------------------------------------------

  defp uninstall_all(igniter, opts) do
    igniter =
      Enum.reduce(phoenix_apps(), igniter, fn app_path, acc ->
        uninstall_app(acc, app_path)
      end)

    igniter = uninstall_edge_app(igniter, opts)
    State.reset()
    igniter
  end

  defp uninstall_app(igniter, app_path) do
    case find_file(app_path, "endpoint.ex") do
      nil -> igniter
      file -> Extension.remove_edge_context_plug(igniter, file)
    end
  end

  defp uninstall_edge_app(igniter, opts) do
    gateway_app = opts[:gateway_app] || "gateway"

    if opts[:remove_gateway] do
      [
        "apps/#{gateway_app}/mix.exs",
        "apps/#{gateway_app}/lib/#{gateway_app}/application.ex",
        "apps/#{gateway_app}/lib/#{gateway_app}/endpoint.ex"
      ]
      |> Enum.reduce(igniter, fn path, acc ->
        if Igniter.exists?(acc, path), do: Igniter.rm(acc, path), else: acc
      end)
    else
      case find_edge_endpoint(gateway_app) do
        nil ->
          igniter

        file ->
          igniter
          |> Extension.remove_edge_proxy_endpoint(file)
          |> Extension.remove_metrics_plug(file)
      end
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

  defp find_edge_endpoint(gateway_app) do
    Path.wildcard("apps/{#{gateway_app},edge_proxy}/lib/**/*endpoint.ex")
    |> List.first()
  end

  defp find_file(app_path, suffix) do
    Path.join(app_path, "lib/**/*#{suffix}")
    |> Path.wildcard()
    |> List.first()
  end

  # ------------------------------------------------------------
  # SCAFFOLD TEMPLATES
  # ------------------------------------------------------------

  defp gateway_mix_template(app_name, mod_name) do
    """
    defmodule #{mod_name}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app_name},
          version: "0.1.0",
          build_path: "../../_build",
          config_path: "../../config/config.exs",
          deps_path: "../../deps",
          lockfile: "../../mix.lock",
          elixir: "~> 1.16",
          start_permanent: Mix.env() == :prod,
          deps: deps()
        ]
      end

      def application do
        [
          extra_applications: [:logger],
          mod: {#{mod_name}.Application, []}
        ]
      end

      defp deps do
        [
          {:edge_proxy, in_umbrella: true},
          {:bandit, "~> 1.5"}
        ]
      end
    end
    """
  end

  defp gateway_app_template(mod_name, port) do
    """
    defmodule #{mod_name}.Application do
      use Application

      @impl true
      def start(_type, _args) do
        port = String.to_integer(System.get_env("GATEWAY_PORT") || "#{port}")

        children = [
          {Bandit, plug: #{mod_name}.Endpoint, port: port}
        ]

        opts = [strategy: :one_for_one, name: #{mod_name}.Supervisor]
        Supervisor.start_link(children, opts)
      end
    end
    """
  end

  defp gateway_endpoint_template(mod_name, telemetry?) do
    metrics_line = if telemetry?, do: "  plug EdgeProxy.Metrics.Plug\n", else: ""

    """
    defmodule #{mod_name}.Endpoint do
      use Plug.Builder

      plug Plug.Logger
    #{metrics_line}  plug EdgeProxy.Control.Plug
      plug EdgeProxy.Plug.Router
    end
    """
  end

  defp default_routes_json do
    """
    [
      {
        "tenant": "any",
        "host": "*.mesh.local",
        "path": "/",
        "upstream": {
          "type": "http",
          "host": "127.0.0.1",
          "port": 4001
        }
      }
    ]
    """
  end
end
