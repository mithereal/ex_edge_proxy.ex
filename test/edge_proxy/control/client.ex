defmodule EdgeProxy.Control.Client do
  @moduledoc """
  Client for sending HMAC-signed runtime commands to `EdgeProxy.Control.Plug`
  (`POST /__edge_control__`).

  Uses Erlang's built-in `:httpc` so no extra HTTP client dependency is required.
  """

  alias EdgeProxy.Control.Security

  @default_url "http://127.0.0__"

  # ------------------------------------------------------------
  # PUBLIC COMMAND API
  # ------------------------------------------------------------

  @doc """
  Adds or replaces routes for an exact domain on the target EdgeProxy node.
  """
  def put_domain(domain, routes, opts \\ []) when is_binary(domain) and is_list(routes) do
    send_command(
      %{
        "type" => "put_domain",
        "domain" => domain,
        "routes" => normalize_routes(routes)
      },
      opts
    )
  end

  @doc """
  Adds or replaces routes for a wildcard host pattern (e.g., `"*.mesh.local"`).
  """
  def put_wildcard(pattern, routes, opts \\ []) when is_binary(pattern) and is_list(routes) do
    send_command(
      %{
        "type" => "put_wildcard",
        "pattern" => pattern,
        "routes" => normalize_routes(routes)
      },
      opts
    )
  end

  @doc """
  Deletes all routes matching `domain`.
  """
  def delete_domain(domain, opts \\ []) when is_binary(domain) do
    send_command(
      %{
        "type" => "delete_domain",
        "domain" => domain
      },
      opts
    )
  end

  @doc """
  Opens (`:open` / `"open"`) or closes (`:closed` / `"close"`) the circuit breaker for `tenant`.
  """
  def set_circuit_breaker(tenant, state, opts \\ []) when is_binary(tenant) do
    cb_state =
      case state do
        s when s in [:open, "open"] -> "open"
        s when s in [:closed, :close, "closed", "close"] -> "close"
        other -> to_string(other)
      end

    send_command(
      %{
        "type" => "set_circuit_breaker",
        "tenant" => tenant,
        "state" => cb_state
      },
      Keyword.put_new(opts, :tenant, tenant)
    )
  end

  @doc """
  Sends a signed health/auth verification ping (`noop`) to the control endpoint.
  """
  def ping(opts \\ []) do
    send_command(%{"type" => "noop"}, opts)
  end

  # ------------------------------------------------------------
  # PAYLOAD SIGNING & TRANSPORT
  # ------------------------------------------------------------

  @doc """
  Builds and signs a control payload map with `tenant`, `nonce`, `ts`, and `sig`.
  """
  def build_signed_payload(command, opts \\ []) when is_map(command) do
    tenant = Keyword.get(opts, :tenant, "system")
    secret = Keyword.get(opts, :secret)

    unsigned =
      command
      |> Map.put_new("tenant", tenant)
      |> Map.put("nonce", generate_nonce())
      |> Map.put("ts", System.system_time(:second))

    sig =
      if secret do
        sign_with_secret(unsigned, secret)
      else
        Security.sign(unsigned)
      end

    Map.put(unsigned, "sig", sig)
  end

  @doc """
  Signs and sends a raw command map to `:local` or a remote `:url`.
  """
  def send_command(command, opts \\ []) when is_map(command) do
    signed = build_signed_payload(command, opts)

    case Keyword.get(opts, :url, default_url()) do
      :local ->
        EdgeProxy.Control.Socket.handle_command(signed)

      url when is_binary(url) ->
        post_json(url, signed, opts)
    end
  end

  defp post_json(url, payload, opts) do
    ensure_httpc_started()

    body = Jason.encode!(payload)
    timeout = Keyword.get(opts, :timeout, 5_000)

    request = {
      String.to_charlist(url),
      [{~c"accept", ~c"application/json"}],
      ~c"application/json",
      body
    }

    http_opts = [timeout: timeout, connect_timeout: timeout]

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, _resp_body}} ->
        :ok

      {:ok, {{_version, status, _reason}, _headers, resp_body}} ->
        {:error, {:http_error, status, decode_error(resp_body)}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp normalize_routes(routes) do
    Enum.map(routes, fn route ->
      for {k, v} <- route, into: %{} do
        {to_string(k), stringify_keys(v)}
      end
    end)
  end

  defp stringify_keys(%{} = map) do
    for {k, v} <- map, into: %{}, do: {to_string(k), stringify_keys(v)}
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(val), do: val

  defp sign_with_secret(data, secret) do
    payload =
      data
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join("&", fn
        {k, v} when is_binary(v) or is_number(v) or is_atom(v) -> "#{k}=#{v}"
        {k, v} -> "#{k}=#{Jason.encode!(v)}"
      end)

    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  defp generate_nonce do
    Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end

  defp default_url do
    Application.get_env(:edge_proxy, :control_url, @default_url)
  end

  defp ensure_httpc_started do
    :inets.start()
    :ssl.start()
  end

  defp decode_error(body) do
    case Jason.decode(body) do
      {:ok, map} -> map
      _ -> body
    end
  end
end
