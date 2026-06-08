defmodule EdgeProxy.Routing.PathRouter do
  @moduledoc """
  Path-based router for EdgeProxy.

  Responsibilities:
  - match incoming request path + host + tenant headers
  - resolve upstream Phoenix app
  - support wildcard domains
  - support mixed routing per domain
  - apply circuit breaker rules
  """

  require Logger

  alias EdgeProxy.Routing.Runtime

  # ------------------------------------------------------------
  # PUBLIC API
  # ------------------------------------------------------------

  @doc """
  Resolve a request into an upstream route.

  Input:
    conn-like map with:
      - host
      - path
      - headers (x-edge-tenant, etc.)

  Output:
    {:ok, route} | {:error, reason}
  """
  def resolve(conn) do
    tenant = header(conn, "x-edge-tenant")
    host = normalize_host(conn.host)
    path = conn.request_path

    cond do
      circuit_open?(tenant) ->
        {:error, :circuit_open}

      true ->
        route =
          match_route(%{
            tenant: tenant,
            host: host,
            path: path
          })

        case route do
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

  # ------------------------------------------------------------
  # TENANT MATCHING
  # ------------------------------------------------------------

  defp match_tenant?(route, ctx) do
    route.tenant == ctx.tenant or route.tenant == :any
  end

  # ------------------------------------------------------------
  # HOST MATCHING (WILDCARDS SUPPORTED)
  # ------------------------------------------------------------

  defp match_host?(route, host) do
    case route.host do
      :any ->
        true

      "*" <> suffix ->
        String.ends_with?(host, suffix)

      exact ->
        host == exact
    end
  end

  # ------------------------------------------------------------
  # PATH MATCHING (PREFIX + MIXED ROUTING SUPPORT)
  # ------------------------------------------------------------

  defp match_path?(route, path) do
    case route.path do
      :any ->
        true

      prefix when is_binary(prefix) ->
        String.starts_with?(path, prefix)

      regex when is_struct(regex, Regex) ->
        Regex.match?(regex, path)
    end
  end

  # ------------------------------------------------------------
  # CIRCUIT BREAKER CHECK
  # ------------------------------------------------------------

  defp circuit_open?(tenant) do
    Runtime.circuit_open?(tenant)
  end

  # ------------------------------------------------------------
  # ROUTE NORMALIZATION
  # ------------------------------------------------------------

  defp normalize_route(nil, _ctx), do: nil

  defp normalize_route(route, ctx) do
    %{
      upstream: route.upstream,
      tenant: ctx.tenant,
      host: ctx.host,
      path: ctx.path,
      opts: route.opts || %{}
    }
  end

  # ------------------------------------------------------------
  # HELPERS
  # ------------------------------------------------------------

  defp header(conn, key) do
    conn.headers
    |> Enum.find_value(fn {k, v} ->
      if String.downcase(k) == key, do: v
    end)
  end

  defp normalize_host(host) do
    host
    |> String.downcase()
    |> String.trim()
  end
end