defmodule EdgeProxy.Domain.Registry do
  use GenServer

  @table :edge_domains
  @wildcards :edge_wildcards

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :ets.new(@wildcards, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  def put_domain(domain, routes) do
    :ets.insert(@table, {domain, routes})
  end

  def put_wildcard(pattern, routes) do
    :ets.insert(@wildcards, {pattern, routes})
  end

  def resolve(host) do
    case :ets.lookup(@table, host) do
      [{^host, routes}] -> {:ok, routes}
      _ -> resolve_wildcard(host)
    end
  end

  defp resolve_wildcard(host) do
    :ets.tab2list(@wildcards)
    |> Enum.find_value(fn
      {"*." <> suffix, routes} ->
        if String.ends_with?(host, suffix), do: {:ok, routes}

      _ ->
        false
    end) || :error
  end
end
