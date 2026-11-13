defmodule Mix.Tasks.EdgeProxy.Install do
  @shortdoc "Installs EdgeProxy across umbrella or Phoenix apps using Igniter"

  @moduledoc """
  Installs EdgeProxy into an edge gateway app and wires `EdgeContract`
  into downstream Phoenix apps. See the full source code in the repository for complete implementation details.
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
      "edge" -> install_edge_app(igniter, opts)
      "apps" -> install_phoenix_apps(igniter)
      "uninstall" -> uninstall_all(igniter, opts)
      _ ->
        igniter
        |> install_edge_app(opts)
        |> install_phoenix_apps()
    end
  end

  # Edge and Phoenix app installation and uninstallation logic abbreviated.
  # Please refer to the project repository for full task implementations and scaffolding templates.
end
