defmodule EdgeProxy.Metrics.Plug do
  @moduledoc """
  Exposes Prometheus metrics at `GET /metrics`.

  Optional config:
      config :edge_proxy, metrics_token: "my_scrape_secret"
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{path_info: ["metrics"], method: "GET"} = conn, _opts) do
    if authorized?(conn) do
      conn
      |> put_resp_content_type("text/plain; version=0.0.4; charset=utf-8")
      |> send_resp(200, EdgeProxy.Telemetry.scrape())
      |> halt()
    else
      conn
      |> send_resp(401, "Unauthorized")
      |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp authorized?(conn) do
    case Application.get_env(:edge_proxy, :metrics_token) do
      nil ->
        true

      expected ->
        get_req_header(conn, "authorization") == ["Bearer #{expected}"]
    end
  end
end
