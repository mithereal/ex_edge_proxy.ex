defmodule EdgeProxy.Plug.Router do
  @moduledoc """
  Alias Plug delegating to `EdgeProxy`.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: EdgeProxy.init(opts)

  @impl true
  def call(conn, opts), do: EdgeProxy.call(conn, opts)
end
