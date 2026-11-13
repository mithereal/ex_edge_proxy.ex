defmodule EdgeProxy.State do
  @moduledoc """
  Persists EdgeProxy installation state across umbrella apps in `.edge_proxy_state.json`.
  """

  @state_file ".edge_proxy_state.json"

  def mark(app, key, value) do
    state = read()
    app_state = Map.get(state, app, %{}) |> Map.put(key, value)
    write(Map.put(state, app, app_state))
  end

  def get(app, key, default \\ nil) do
    read()
    |> Map.get(app, %{})
    |> Map.get(key, default)
  end

  def reset do
    if File.exists?(@state_file), do: File.rm!(@state_file)
    :ok
  end

  defp read do
    case File.read(@state_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp write(state) do
    File.write!(@state_file, Jason.encode!(state, pretty: true))
    :ok
  end
end
