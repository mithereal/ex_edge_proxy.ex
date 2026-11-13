defmodule EdgeProxy.BackplaneClient do
  @moduledoc """
  Internal service-to-service HTTP client that routes requests over the private
  `ex_service_mesh_router` backplane while preserving `EdgeContract` headers
  (`x-edge-tenant`, `x-edge-domain`, `x-request-id`).

  Built directly on `Mint.HTTP` and `Jason` with zero external HTTP client dependencies.
  """

  require Logger

  @default_mesh_url "http://127.0.0.1:4040"

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @type request_opt ::
          {:method, atom() | String.t()}
          | {:headers, [{String.t(), String.t()}]}

          | {:body, iodata() | nil}
          | {:json, term()}

          | {:params, keyword() | map()}
          | {:conn, Plug.Conn.t()}
          | {:socket, map()}
          | {:tenant, String.t()}
          | {:domain, String.t()}
          | {:request_id, String.t()}
          | {:mesh_url, String.t()}
          | {:receive_timeout, pos_integer()}

  @doc """
  Sends an internal backplane request to a registered mesh service (e.g., `"auth.mesh.local"`).
  """
  @spec request(String.t(), String.t(), [request_opt()]) ::
          {:ok, response()} | {:error, term()}
  def request(target_service, path, opts \\ []) when is_binary(target_service) and is_binary(path) do
    mesh_url =
      Keyword.get(
        opts,
        :mesh_url,
        Application.get_env(:edge_proxy, :mesh_backplane_url, @default_mesh_url)
      )

    uri = URI.parse(mesh_url)
    scheme = parse_scheme(uri.scheme)
    host = uri.host || "127.0.0.1"
    port = uri.port || default_port(scheme)

    method = opts |> Keyword.get(:method, :get) |> normalize_method()
    request_path = build_path(uri.path, path, Keyword.get(opts, :params))
    timeout = Keyword.get(opts, :receive_timeout, 15_000)

    {body, extra_headers} = encode_body(opts)

    headers =
      [{"x-backplane-service", target_service}]
      |> merge_headers(extra_headers)
      |> merge_headers(extract_contract_headers(opts))
      |> merge_headers(Keyword.get(opts, :headers, []))

    with {:ok, conn} <- Mint.HTTP.connect(scheme, host, port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, method, request_path, headers, body),
         {:ok, conn, response} <- receive_response(conn, ref, timeout) do
      Mint.HTTP.close(conn)
      classify_response(target_service, response)
    else
      {:error, conn, reason, _responses} ->
        Mint.HTTP.close(conn)
        log_transport_error(target_service, reason)
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        log_transport_error(target_service, reason)
        {:error, {:transport_error, reason}}
    end
  end

  defp classify_response(target_service, %{status: status} = resp) when status in 200..299 do
    _ = target_service
    {:ok, resp}
  end

  defp classify_response(target_service, %{status: 502} = resp) do
    Logger.warning(
      "[EdgeProxy.BackplaneClient] Target service '#{target_service}' unreachable or unregistered on mesh"
    )

    {:error, {:service_unavailable, resp}}
  end

  defp classify_response(_target_service, %{status: status} = resp) do
    {:error, {:http_error, status, resp}}
  end

  defp log_transport_error(target_service, reason) do
    Logger.error(
      "[EdgeProxy.BackplaneClient] Mesh transport failure calling '#{target_service}': #{inspect(reason)}"
    )
  end

  # Mint HTTP Response Loop

  defp receive_response(conn, ref, timeout) do
    receive_loop(conn, ref, timeout, %{status: nil, headers: [], body: []})
  end

  defp receive_loop(conn, ref, timeout, acc) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          :unknown ->
            receive_loop(conn, ref, timeout, acc)

          {:ok, conn, responses} ->
            case handle_responses(responses, ref, acc) do
              {:done, final_resp} -> {:ok, conn, final_resp}
              {:continue, new_acc} -> receive_loop(conn, ref, timeout, new_acc)
            end

          {:error, conn, reason, responses} ->
            {:error, conn, reason, responses}
        end
    after
      timeout ->
        {:error, conn, :timeout, []}
    end
  end

  defp handle_responses([], _ref, acc), do: {:continue, acc}

  defp handle_responses([{:status, ref, status} | rest], ref, acc) do
    handle_responses(rest, ref, %{acc | status: status})
  end

  defp handle_responses([{:headers, ref, headers} | rest], ref, acc) do
    handle_responses(rest, ref, %{acc | headers: acc.headers ++ headers})
  end

  defp handle_responses([{:data, ref, chunk} | rest], ref, acc) do
    handle_responses(rest, ref, %{acc | body: [chunk | acc.body]})
  end

  defp handle_responses([{:done, ref} | _rest], ref, acc) do
    final_body = acc.body |> Enum.reverse() |> IO.iodata_to_binary()
    {:done, %{acc | body: final_body}}
  end

  defp handle_responses([_other | rest], ref, acc) do
    handle_responses(rest, ref, acc)
  end

  # Helpers

  defp parse_scheme("https"), do: :https
  defp parse_scheme(_), do: :http

  defp default_port(:https), do: 443
  defp default_port(:http), do: 80

  defp normalize_method(method) when is_atom(method),
    do: method |> Atom.to_string() |> String.upcase()

  defp normalize_method(method) when is_binary(method), do: String.upcase(method)

  defp build_path(base_path, path, params) do
    prefix = if is_binary(base_path), do: String.trim_trailing(base_path, "/"), else: ""
    clean_path = "/" <> String.trim_leading(path, "/")
    full_path = prefix <> clean_path

    case params do
      nil ->
        full_path

      empty when empty == [] or empty == %{} ->
        full_path

      query_params ->
        query = URI.encode_query(query_params)
        separator = if String.contains?(full_path, "?"), do: "&", else: "?"
        full_path <> separator <> query
    end
  end

  defp encode_body(opts) do
    cond do
      Keyword.has_key?(opts, :json) ->
        {Jason.encode!(Keyword.fetch!(opts, :json)), [{"content-type", "application/json"}]}

      Keyword.get(opts, :body) != nil ->
        {Keyword.get(opts, :body), []}

      true ->
        {nil, []}
    end
  end

  defp extract_contract_headers(opts) do
    {conn_tenant, conn_domain, conn_req_id} =
      case Keyword.get(opts, :conn) do
        %Plug.Conn{} = conn ->
          {
            get_req_header(conn, "x-edge-tenant") ||
              get_in(conn.assigns, [:edge_contract, :tenant]),
            get_req_header(conn, "x-edge-domain") ||
              get_in(conn.assigns, [:edge_contract, :domain]),
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
end
