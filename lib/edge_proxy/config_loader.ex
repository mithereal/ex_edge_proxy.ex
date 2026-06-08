defmodule EdgeProxy.Config.Loader do
  @moduledoc """
  Loads EdgeProxy routing configuration.

  Default behavior:
  - reads config from the *application that started EdgeProxy*
  - falls back to project-local file if not found
  """

  @default_rel_path "edge_proxy/routes.json"

  # ------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------

  @doc """
  Boot-time loader.

  Default path is resolved from the *host application* root.
  """
  def load(opts \\ []) do
    app = Keyword.get(opts, :app, app_name())
    path = Keyword.get(opts, :path, default_path(app))

    routes =
      path
      |> load_file()
      |> apply_env_overrides()
      |> normalize()

    EdgeProxy.Routing.Runtime.update(routes)

    routes
  end

  # ------------------------------------------------------------
  # DEFAULT PATH RESOLUTION
  # ------------------------------------------------------------

  defp default_path(app) do
    case :code.priv_dir(app) do
      priv when is_list(priv) ->
        priv
        |> to_string()
        |> Path.join("../#{@default_rel_path}")
        |> Path.expand()

      _ ->
        Path.expand(@default_rel_path)
    end
  rescue
    _ ->
      Path.expand(@default_rel_path)
  end

  defp app_name do
    case Application.started_applications() do
      apps when is_list(apps) ->
        apps
        |> Enum.find(fn {name, _, _} ->
          name not in [:kernel, :stdlib, :sasl]
        end)
        |> case do
             {name, _, _} -> name
             _ -> :edge_proxy
           end

      _ ->
        :edge_proxy
    end
  end

  # ------------------------------------------------------------
  # FILE LOADING
  # ------------------------------------------------------------

  defp load_file(path) do
    case File.read(path) do
      {:ok, content} -> decode(content)
      _ -> []
    end
  end

  # ------------------------------------------------------------
  # JSON PARSING
  # ------------------------------------------------------------

  defp decode(content) do
    case Jason.decode(content) do
      {:ok, data} -> data
      _ -> []
    end
  end

  # ------------------------------------------------------------
  # ENV OVERRIDES
  # ------------------------------------------------------------

  defp apply_env_overrides(routes) do
    case System.get_env("EDGE_TENANT_DEFAULT") do
      nil ->
        routes

      tenant ->
        Enum.map(routes, fn route ->
          Map.put_new(route, "tenant", tenant)
        end)
    end
  end

  # ------------------------------------------------------------
  # NORMALIZATION
  # ------------------------------------------------------------

  defp normalize(routes) do
    Enum.map(routes, &normalize_route/1)
  end

  defp normalize_route(route) do
    %{
      tenant: parse(route["tenant"] || :any),
      host: route["host"] || :any,
      path: route["path"] || "/",
      upstream: parse_upstream(route["upstream"]),
      opts: route["opts"] || %{}
    }
  end

  # ------------------------------------------------------------
  # UPSTREAM PARSING
  # ------------------------------------------------------------

  defp parse_upstream(%{"type" => "http", "host" => host, "port" => port}) do
    {:http, host, port}
  end

  defp parse_upstream(%{"type" => "https", "host" => host, "port" => port}) do
    {:https, host, port}
  end

  defp parse_upstream(other), do: other

  defp parse(:any), do: :any
  defp parse(val) when is_binary(val), do: val
  defp parse(val), do: val
end