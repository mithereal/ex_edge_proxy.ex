defmodule EdgeProxy.Plug.Router do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, domain_route} <- EdgeProxy.Domain.Registry.resolve(conn.host),
         app <- EdgeProxy.Routing.PathRouter.resolve(conn.request_path),
         {:ok, route} <- Map.fetch(domain_route.routes, app) do
      dispatch(conn, route)
    else
      _ -> send_resp(conn, 404, "no route")
    end
  end

  defp dispatch(conn, route) do
    if liveview_request?(conn) do
      EdgeProxy.LiveView.Session.start(conn, route)
    else
      EdgeProxy.HTTP.Forwarder.forward(conn, route)
    end
  end

  defp liveview_request?(conn) do
    get_req_header(conn, "upgrade") == ["websocket"]
  end
end
