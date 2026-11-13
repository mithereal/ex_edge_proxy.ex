defmodule EdgeContract.TenantEnforcer do
  @moduledoc """
  Applies optional Ecto and Ash multi-tenant isolation from an `%EdgeProxy.EdgeContract{}`.
  """

  @compile {:no_warn_undefined, Ash}

  alias EdgeProxy.EdgeContract

  def apply(%EdgeContract{tenant: tenant}) when is_binary(tenant) and tenant != "" do
    maybe_set_ecto_tenant(tenant)
    maybe_set_ash_tenant(tenant)
    :ok
  end

  def apply(_contract), do: :ok

  defp maybe_set_ecto_tenant(tenant) do
    if Application.get_env(:edge_proxy, :enable_ecto_tenant, false) do
      repo = Application.get_env(:edge_proxy, :ecto_repo)

      if repo && Code.ensure_loaded?(repo) && function_exported?(repo, :put_tenant, 1) do
        repo.put_tenant(tenant)
      end
    end
  end

  defp maybe_set_ash_tenant(tenant) do
    if Application.get_env(:edge_proxy, :enable_ash_tenant, false) and Code.ensure_loaded?(Ash) do
      Ash.set_tenant(tenant)
    end
  end
end
