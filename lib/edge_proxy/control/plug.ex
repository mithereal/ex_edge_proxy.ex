defmodule EdgeProxy.Control.Plug do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.path_info do
      ["__edge_control__"] ->
        {:ok, conn}
        |> upgrade_to_ws()

      _ ->
        conn
    end
  end

  defp upgrade_to_ws(conn) do
    # delegated to Phoenix/WebSocket adapter in real deployment
    send_resp(conn, 200, "control endpoint placeholder")
  end
end
