defmodule EdgeContract.LiveView do
  @moduledoc """
  LiveView `on_mount` hook restoring `EdgeContract` from session or connect_info
  into `socket.assigns.edge`.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias EdgeProxy.EdgeContract

  def on_mount(:default, _params, session, socket) do
    contract = resolve_contract(session, socket)
    {:cont, assign(socket, :edge, contract)}
  end

  def on_mount(:require_tenant, _params, session, socket) do
    case resolve_contract(session, socket) do
      %EdgeContract{tenant: tenant} = contract when is_binary(tenant) and tenant != "" ->
        {:cont, assign(socket, :edge, contract)}

      _ ->
        {:halt, redirect(socket, to: "/")}
    end
  end

  defp resolve_contract(session, socket) do
    cond do
      is_map(session["edge_contract"]) ->
        struct(EdgeContract, atomize_keys(session["edge_contract"]))

      match?(%EdgeContract{}, get_connect_info(socket, :edge)) ->
        get_connect_info(socket, :edge)

      true ->
        %EdgeContract{}
    end
  end

  defp atomize_keys(map) do
    for {k, v} <- map, into: %{} do
      key = if is_binary(k), do: String.to_existing_atom(k), else: k
      {key, v}
    end
  rescue
    ArgumentError -> %{}
  end
end
