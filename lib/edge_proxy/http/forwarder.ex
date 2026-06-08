defmodule EdgeProxy.HTTP.Forwarder do
  def forward(conn, %{upstream: upstream}) do
    {:ok, mint_conn} =
      Mint.HTTP.connect(:http, upstream.host, upstream.port)

    {:ok, mint_conn, req_ref} =
      Mint.HTTP.request(
        mint_conn,
        conn.method,
        conn.request_path,
        conn.req_headers,
        {:stream, conn}
      )

    stream_response(conn, mint_conn, req_ref)
  end

  defp stream_response(conn, _mint_conn, _ref) do
    Plug.Conn.send_resp(conn, 200, "proxied")
  end
end
