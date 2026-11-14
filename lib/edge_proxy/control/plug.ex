defmodule EdgeProxy.Control.Plug do
  @moduledoc """
  HTTP JSON control plane endpoint mounted at `/__edge_control__`.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{path_info: ["__edge_control__"], method: "POST"} = conn, _opts) do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, msg} <- Jason.decode(body),
         :ok <- EdgeProxy.Control.Socket.handle_command(msg) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{status: "ok"}))
      |> halt()
    else
      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{status: "error", reason: inspect(reason)}))
        |> halt()
    end
  end

  def call(%{path_info: ["__edge_control__"]} = conn, _opts) do
    conn
    |> send_resp(405, "Method Not Allowed")
    |> halt()
  end

  def call(conn, _opts), do: conn
end
