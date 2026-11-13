defmodule EdgeContract.Plug do
  @moduledoc """
  Extracts EdgeContract headers injected by EdgeProxy into `conn.assigns.edge`,
  stores them in the session for LiveView consumption, and applies optional
  Ecto/Ash tenant isolation.
  """

  @behaviour Plug
  import Plug.Conn

  alias EdgeContract.TenantEnforcer
  alias EdgeProxy.EdgeContract

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    contract = %EdgeContract{
      tenant: first_header(conn, "x-edge-tenant"),
      domain: first_header(conn, "x-edge-domain"),
      request_id: first_header(conn, "x-request-id"),
      auth_context: decode_auth_context(first_header(conn, "x-edge-auth"))
    }

    TenantEnforcer.apply(contract)

    conn
    |> assign(:edge, contract)
    |> maybe_put_session(contract)
  end

  defp first_header(conn, key) do
    case get_req_header(conn, key) do
      [val | _] when val != "" -> val
      _ -> nil
    end
  end

  defp decode_auth_context(nil), do: nil

  defp decode_auth_context(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, map} <- Jason.decode(json) do
      map
    else
      _ -> nil
    end
  end

  defp maybe_put_session(%{private: %{plug_session_fetch: :done}} = conn, contract) do
    put_session(conn, "edge_contract", Map.from_struct(contract))
  end

  defp maybe_put_session(conn, _contract), do: conn
end
