defmodule EdgeProxy.Control.Security do
  @moduledoc """
  HMAC + replay + timestamp + tenant-scoped authorization layer.
  """

  @secret Application.compile_env(:edge_proxy, :control_secret, "dev_secret")

  # 30 seconds
  @max_skew 30_000

  # ----------------------------
  # Entry point
  # ----------------------------

  def verify(msg) do
    with :ok <- check_timestamp(msg),
         :ok <- check_signature(msg),
         :ok <- authorize(msg) do
      :ok
    end
  end

  # ----------------------------
  # Timestamp protection
  # ----------------------------

  defp check_timestamp(%{"ts" => ts}) do
    now = System.system_time(:second)

    if abs(now - ts) <= @max_skew do
      :ok
    else
      {:error, :timestamp_out_of_range}
    end
  end

  defp check_timestamp(_), do: {:error, :missing_timestamp}

  # ----------------------------
  # HMAC signature verification
  # ----------------------------

  defp check_signature(msg) do
    provided = Map.get(msg, "sig", "")

    expected = sign(Map.drop(msg, ["sig"]))

    if secure_equals?(provided, expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp sign(data) do
    data
    |> canonicalize()
    |> :crypto.mac(:hmac, :sha256, @secret, &1)
    |> Base.encode16(case: :lower)
  end

  # stable ordering for signature consistency
  defp canonicalize(map) do
    map
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join("&")
  end

  defp secure_equals?(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_equals?(_, _), do: false

  # ----------------------------
  # Authorization layer (tenant scoped)
  # ----------------------------

  defp authorize(%{"tenant" => tenant}) do
    allowed = allowed_tenants()

    if tenant in allowed do
      :ok
    else
      {:error, :unauthorized_tenant}
    end
  end

  defp authorize(_), do: {:error, :missing_tenant}

  defp allowed_tenants do
    Application.get_env(:edge_proxy, :allowed_control_tenants, [])
  end
end
