defmodule EdgeProxy.Control.Security do
  @moduledoc """
  HMAC-SHA256 + timestamp + tenant-scoped authorization layer.
  """

  # 30 seconds (in seconds, matching System.system_time(:second))
  @max_skew 30

  def verify(msg) when is_map(msg) do
    with :ok <- check_timestamp(msg),
         :ok <- check_signature(msg),
         :ok <- authorize(msg) do
      :ok
    end
  end

  def verify(_), do: {:error, :invalid_payload}

  # ------------------------------------------------------------
  # TIMESTAMP PROTECTION
  # ------------------------------------------------------------

  defp check_timestamp(%{"ts" => ts}) when is_integer(ts) do
    now = System.system_time(:second)

    if abs(now - ts) <= @max_skew do
      :ok
    else
      {:error, :timestamp_out_of_range}
    end
  end

  defp check_timestamp(_), do: {:error, :missing_or_invalid_timestamp}

  # ------------------------------------------------------------
  # HMAC SIGNATURE VERIFICATION
  # ------------------------------------------------------------

  defp check_signature(%{"sig" => provided} = msg) when is_binary(provided) do
    expected =
      msg
      |> Map.drop(["sig"])
      |> sign()

    if secure_equals?(String.downcase(provided), expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp check_signature(_), do: {:error, :missing_signature}

  def sign(data) do
    secret = Application.get_env(:edge_proxy, :control_secret, "dev_secret")
    payload = canonicalize(data)

    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  defp canonicalize(map) do
    map
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{canonical_value(v)}" end)
  end

  defp canonical_value(v) when is_binary(v) or is_number(v) or is_atom(v), do: to_string(v)
  defp canonical_value(v), do: Jason.encode!(v)

  defp secure_equals?(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_equals?(_, _), do: false

  # ------------------------------------------------------------
  # AUTHORIZATION LAYER
  # ------------------------------------------------------------

  defp authorize(%{"tenant" => tenant}) when is_binary(tenant) do
    case Application.get_env(:edge_proxy, :allowed_control_tenants, :all) do
      :all ->
        :ok

      allowed when is_list(allowed) ->
        if tenant in allowed, do: :ok, else: {:error, :unauthorized_tenant}
    end
  end

  defp authorize(_), do: {:error, :missing_tenant}
end
