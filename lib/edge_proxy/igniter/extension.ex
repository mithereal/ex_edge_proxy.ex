defmodule EdgeProxy.Igniter.Extension do
  @moduledoc """
  Strict AST transformations for EdgeProxy system.
  """

  # ------------------------------------------------------------
  # EDGE PROXY APP (ONLY ROUTING APP)
  # ------------------------------------------------------------

  def inject_edge_proxy_endpoint(ast) do
    Igniter.after_use(ast, Phoenix.Endpoint, fn block ->
      quote do
        unquote(block)
        plug EdgeProxy.Router
      end
    end)
  end

  def remove_edge_proxy_endpoint(ast) do
    Igniter.remove_plug(ast, EdgeProxy.Router)
  end

  # ------------------------------------------------------------
  # PHOENIX APPS (CONTEXT ONLY)
  # ------------------------------------------------------------

  def inject_edge_context_plug(ast) do
    Igniter.after_use(ast, Phoenix.Endpoint, fn block ->
      quote do
        unquote(block)
        plug EdgeContract.Plug
      end
    end)
  end

  def remove_edge_context_plug(ast) do
    Igniter.remove_plug(ast, EdgeContract.Plug)
  end

  def inject_liveview_hook(ast) do
    Igniter.append_liveview_on_mount(ast, EdgeContract.LiveView)
  end

  def inject_socket_context(ast) do
    Igniter.append_function(ast, quote do
      def connect(_params, socket, connect_info) do
        {:ok, assign(socket, :edge, connect_info[:edge])}
      end
    end)
  end
end