defmodule EdgeProxy.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EdgeProxy.Routing.Runtime,
      EdgeProxy.LiveView.SessionSupervisor,
      EdgeProxy.Control.Socket
    ]

    opts = [strategy: :one_for_one, name: EdgeProxy.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      EdgeProxy.Config.Loader.load()
      {:ok, pid}
    end
  end
end
