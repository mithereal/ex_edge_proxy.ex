defmodule EdgeProxy.Plug.InternalGuard do
  @moduledoc """
  Blocks external HTTP/WebSocket requests from reaching internal-only mesh hosts
  (e.g., `*.internal.mesh.local`) or injecting `x-backplane-service` headers
  on the public EdgeProxy listener.
  """

  @behaviour Plug
  import Plug.Conn

  @default_internal_patterns [
    ~r/\.internal\.mesh\.local$/i,
    ~r/\.internal\.zone$/i
  ]

  @impl true
  def init(opts) do
    patterns =
      Keyword.get(
        opts,
        :internal_patterns,
        Application.get_env(:ex_edge_proxy, :internal_host_patterns, @default_internal_patterns)
      )

    %{patterns: patterns}
  end

  @impl true
  def call(%Plug.Conn{} = conn, %{patterns: patterns}) do
    host = normalize_host(conn.host)

    cond do
      get_req_header(conn, "x-backplane-service") != [] ->
        reject_request(conn, "Backplane routing headers are forbidden on public ingress")

      internal_host?(host, patterns) ->
        reject_request(conn, "Target host is restricted to internal mesh traffic")

      true ->
        conn
    end
  end

  defp internal_host?(host, patterns) do
    Enum.any?(patterns, fn
      %Regex{} = regex -> Regex.match?(regex, host)
      suffix when is_binary(suffix) -> String.ends_with?(host, suffix)
    end)
  end

  defp normalize_host(nil), do: ""

  defp normalize_host(host) do
    host
    |> String.downcase()
    |> String.split(":")
    |> hd()
  end

  defp reject_request(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, ~s({"error":"forbidden","message":"#{message}"}))
    |> halt()
  end
end
