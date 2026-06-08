defmodule EdgeProxy.Application do
  use Application

  def start(_type, _args) do
    children = [
      EdgeProxy.Routing.Runtime,
      EdgeProxy.Domain.Registry,
      EdgeProxy.LiveView.SessionSupervisor,
      EdgeProxy.Control.Socket
    ]

     Supervisor.start_link(children, strategy: :one_for_one, name: EdgeProxy.Supervisor)
     |> startup()
  end

  def startup(params) do
    EdgeProxy.Config.Loader.load()
    params
  end
end
