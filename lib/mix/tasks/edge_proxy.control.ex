defmodule Mix.Tasks.EdgeProxy.Control do
  @shortdoc "Sends signed runtime commands to a running EdgeProxy control plane"

  @moduledoc """
  CLI wrapper around `EdgeProxy.Control.Client`.

  ## Examples

      mix edge_proxy.control ping --url http://localhost:4000/__edge_control__
      mix edge_proxy.control open-cb tenant1
      mix edge_proxy.control close-cb tenant1
      mix edge_proxy.control put-domain billing.mesh.local /billing 127.0.0.1 4002
      mix edge_proxy.control delete-domain billing.mesh.local
  """

  use Mix.Task

  alias EdgeProxy.Control.Client

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")

    {opts, args, _invalid} =
      OptionParser.parse(argv,
        strict: [url: :string, secret: :string, tenant: :string]
      )

    client_opts =
      []
      |> maybe_put(:url, opts[:url])
      |> maybe_put(:secret, opts[:secret])
      |> maybe_put(:tenant, opts[:tenant])

    result =
      case args do
        ["ping"] ->
          Client.ping(client_opts)

        ["open-cb", tenant] ->
          Client.set_circuit_breaker(tenant, :open, client_opts)

        ["close-cb", tenant] ->
          Client.set_circuit_breaker(tenant, :closed, client_opts)

        ["put-domain", domain, path, host, port] ->
          route = %{
            "path" => path,
            "upstream" => %{"type" => "http", "host" => host, "port" => String.to_integer(port)}
          }

          Client.put_domain(domain, [route], client_opts)

        ["delete-domain", domain] ->
          Client.delete_domain(domain, client_opts)

        _ ->
          Mix.raise("Invalid command. Run `mix help edge_proxy.control` for usage.")
      end

    case result do
      :ok ->
        Mix.shell().info("✅ Control command succeeded")

      {:error, reason} ->
        Mix.raise("❌ Control command failed: #{inspect(reason)}")
    end
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, val), do: Keyword.put(kw, key, val)
end
