defmodule EdgeProxy.Routing.Balancer do
  @moduledoc """
  Weighted load balancer with automatic unhealthy-target exclusion.
  """

  alias EdgeProxy.HealthChecker

  @doc """
  Selects a single upstream target map (`%{scheme, host, port}`) from either:
  - a single upstream map (`%{scheme, host, port}`)
  - a list of weighted upstream maps (`[%{scheme, host, port, weight}, ...]`)
  """
  def select(%{scheme: _, host: _, port: _} = single), do: single

  def select([single]), do: Map.take(single, [:scheme, :host, :port])

  def select(targets) when is_list(targets) and targets != [] do
    healthy =
      Enum.filter(targets, fn t ->
        HealthChecker.healthy?({t.scheme, t.host, t.port})
      end)

    pool = if healthy == [], do: targets, else: healthy
    pick_weighted(pool)
  end

  defp pick_weighted([single]), do: Map.take(single, [:scheme, :host, :port])

  defp pick_weighted(targets) do
    total_weight =
      Enum.reduce(targets, 0, fn t, acc ->
        acc + max(Map.get(t, :weight, 1), 1)
      end)

    roll = :rand.uniform(total_weight)

    targets
    |> Enum.reduce_while(0, fn t, acc ->
      next_acc = acc + max(Map.get(t, :weight, 1), 1)

      if roll <= next_acc do
        {:halt, Map.take(t, [:scheme, :host, :port])}
      else
        {:cont, next_acc}
      end
    end)
  end
end
