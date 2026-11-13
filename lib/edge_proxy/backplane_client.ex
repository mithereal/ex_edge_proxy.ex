defmodule EdgeProxy.BackplaneClient do
  @moduledoc """
  Internal service-to-service HTTP client that routes requests over the private
  `ex_service_mesh_router` backplane while preserving `EdgeContract` headers
  (`x-edge-tenant`, `x-edge-domain`, `x-request-id`).
  """

  require Logger

  @default_mesh_url "http://127.0.0.1:4040"

  @type request_opt ::
          {:method, atom()}
          | {:headers, [{String.t(), String.t()}]}

          | {:body, iodata() | nil}
          | {:json, term()}

          | {:params, keyword() | map()}
          | {:conn, Plug.Conn.t()}
          | {:socket, Phoenix.LiveView.Socket.t()}
          | {:tenant, String.t()}
          | {:domain, String.t()}
          | {:request_id, String.t()}
          | {:receive_timeout, pos_integer()}

  @doc """
  Sends an internal backplane request to a registered mesh service (e.g., `"auth.mesh.local"`).

  Automatically extracts `EdgeContract` context from `:conn` or `:socket` if provided,
  or accepts explicit `:tenant`, `:domain`, and `:request_id` options.

  ## Examples

      # From a Phoenix Controller (automatically forwards Plug.Conn EdgeContract headers)
      EdgeProxy.BackplaneClient.request("auth.mesh.local", "/api/v1/verify",
        conn: conn,
        headers: [{"authorization", "Bearer \#{token}"}]
      )

      # From a LiveView or background GenServer
      EdgeProxy.BackplaneClient.request("billing.mesh.local", "/api/v1/invoices",
        method: :post,
        tenant: "tenant1",
        json: %{amount: 5000}
      )
  """
  @spec request(String.t(), String.t(), [request_opt()]) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def request(target_service, path, opts \\ []) when is_binary(target_service) and is_binary(path) do
    mesh_url = Application.get_env(:ex_edge_proxy, :mesh_backplane_url, @default_mesh_url)
    url = String.trim_trailing(mesh_url, "/") <> "/" <> String.trim_leading(path, "/")

    method = Keyword.get(opts, :method, :get)
    user_headers = Keyword.get(opts, :headers, [])
    contract_headers = extract_contract_headers(opts)

    headers =
      [{"x-backplane-service", target_service}]
      |> merge_headers(contract_headers)
      |> merge_headers(user_headers)

    req_opts =
      [
        method: method,
        url: url,
        headers: headers,
        receive_timeout: Keyword.get(opts, :receive_timeout, 15_000)
      ]
      |> maybe_put(:body, Keyword.get(opts, :body))
      |> maybe_put(:json, Keyword.get(opts, :json))
      |> maybe_put(:params, Keyword.get(opts, :params))

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, resp}

      {:ok, %Req.Response{status: 502} = resp} ->
        Logger.warning(
          "[EdgeProxy.BackplaneClient] Target service '#{target_service}' unreachable or unregistered on mesh"
        )

        {:error, {:service_unavailable, resp}}

      {:ok, %Req.Response{} = resp} ->
        {:error, {:http_error, resp.status, resp}}

      {:error, exception} ->
        Logger.error(
          "[EdgeProxy.BackplaneClient] Mesh transport failure calling '#{target_service}': #{inspect(exception)}"
        )

        {:error, {:transport_error, exception}}
    end
  end

  # Extracts EdgeContract context from a Plug.Conn, LiveView.Socket, or explicit opts
  defp extract_contract_headers(opts) do
    {conn_tenant, conn_domain, conn_req_id} =
      case Keyword.get(opts, :conn) do
        %Plug.Conn{} = conn ->
          {
            get_req_header(conn, "x-edge-tenant") || get_in(conn.assigns, [:edge_contract, :tenant]),
            get_req_header(conn, "x-edge-domain") || get_in(conn.assigns, [:edge_contract, :domain]),
            get_req_header(conn, "x-request-id") || Logger.metadata()[:request_id]
          }

        _ ->
          extract_from_socket(Keyword.get(opts, :socket))
      end

    tenant = Keyword.get(opts, :tenant, conn_tenant)
    domain = Keyword.get(opts, :domain, conn_domain)
    request_id = Keyword.get(opts, :request_id, conn_req_id)

    []
    |> maybe_add_header("x-edge-tenant", tenant)
    |> maybe_add_header("x-edge-domain", domain)
    |> maybe_add_header("x-request-id", request_id)
  end

  defp extract_from_socket(%{assigns: assigns}) do
    {
      get_in(assigns, [:edge_contract, :tenant]) || Map.get(assigns, :tenant),
      get_in(assigns, [:edge_contract, :domain]) || Map.get(assigns, :domain),
      get_in(assigns, [:edge_contract, :request_id]) || Logger.metadata()[:request_id]
    }
  end

  defp extract_from_socket(_), do: {nil, nil, Logger.metadata()[:request_id]}

  defp get_req_header(conn, key) do
    case Plug.Conn.get_req_header(conn, key) do
      [val | _] -> val
      _ -> nil
    end
  end

  defp maybe_add_header(headers, _key, nil), do: headers
  defp maybe_add_header(headers, _key, ""), do: headers
  defp maybe_add_header(headers, key, val), do: [{key, to_string(val)} | headers]

  defp merge_headers(base, overrides) do
    override_keys = MapSet.new(overrides, fn {k, _} -> String.downcase(k) end)

    filtered_base =
      Enum.reject(base, fn {k, _} -> MapSet.member?(override_keys, String.downcase(k)) end)

    filtered_base ++ overrides
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
