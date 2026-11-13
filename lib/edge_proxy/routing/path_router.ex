defmodule EdgeProxy.Routing.PathRouter do
  @moduledoc """
  Matches incoming Plug.Conn host, path, and tenant against Runtime routes.
  """

  alias EdgeProxy.Routing.Runtime

  def resolve(conn) do
    tenant = resolve_tenant(conn)
    host = normalize_host(conn.host)
    path = conn.request_path

    if Runtime.circuit_open?(tenant) do
      {:error, :circuit_open}
    else
      case match_route(%{tenant: tenant, host: host, path: path}) do
        nil -> {:error, :no_route}
        route -> {:ok, route}
      end
    end
  end

  # ------------------------------------------------------------
  # ROUTE MATCHING
  # ------------------------------------------------------------

  defp match_route(ctx) do
    Runtime.routes()
    |> Enum.find(fn route ->
      match_tenant?(route, ctx) and
        match_host?(route, ctx.host) and
        match_path?(route, ctx.path)
    end)
    |> normalize_route(ctx)
  end

  defp match_tenant?(%{tenant: :any}, _ctx), do: true
  defp match_tenant?(%{tenant: expected}, %{tenant: actual}), do: expected == actual

  defp match_host?(%{host: :any}, _host), do: true

  defp match_host?(%{host: "*." <> suffix}, host) do
    String.ends_with?(host, "." <> String.downcase(suffix))
  end

  defp match_host?(%{host: "*" <> suffix}, host) do
    String.ends_with?(host, String.downcase(suffix))
  end

  defp match_host?(%{host: exact}, host) when is_binary(exact) do
    host == String.downcase(exact)
  end

  defp match_path?(%{path: :any}, _path), do: true

  defp match_path?(%{path: prefix}, path) when is_binary(prefix) do
    String.starts_with?(path, prefix)
  end

  defp match_path?(%{path: %Regex{} = regex}, path) do
    Regex.match?(regex, path)
  end

  defp normalize_route(nil, _ctx), do: nil

  defp normalize_route(route, ctx) do
    %{
      upstream: EdgeProxy.Routing.Balancer.select(route.upstream),
      tenant: ctx.tenant,
      host: ctx.host,
      path: ctx.path,
      opts: route.opts || %{}
    }
  end


  # ------------------------------------------------------------
  # HELPERS
  # ------------------------------------------------------------

  defp resolve_tenant(conn) do
    case Plug.Conn.get_req_header(conn, "x-edge-tenant") do
      [tenant | _] when tenant != "" ->
        tenant

      _ ->
        extract_subdomain_tenant(conn.host)
    end
  end

  defp extract_subdomain_tenant(nil), do: nil

  defp extract_subdomain_tenant(host) do
    case host |> normalize_host() |> String.split(".") do
      [sub, _domain, _tld | _] when sub not in ["www", "api", "admin"] -> sub
      _ -> nil
    end
  end

  defp normalize_host(nil), do: ""

  defp normalize_host(host) do
    host
    |> String.split(":")
    |> List.first()
    |> String.downcase()
    |> String.trim()
  end
end
