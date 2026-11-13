defmodule EdgeProxy.Igniter.Extension do
  @moduledoc """
  Real Igniter AST transformations for EdgeProxy and downstream Phoenix apps.
  """

  alias Igniter.Code.Common
  alias Igniter.Code.Function
  alias Sourceror.Zipper

  # ------------------------------------------------------------
  # EDGE PROXY APP (ONLY ROUTING APP)
  # ------------------------------------------------------------

  def inject_edge_proxy_endpoint(igniter, path) do
    Igniter.update_elixir_file(igniter, path, fn zipper ->
      if plug_present?(zipper, EdgeProxy.Plug.Router) do
        zipper
      else
        insert_after_use(zipper, Phoenix.Endpoint, "plug EdgeProxy.Plug.Router")
      end
    end)
  end

  def remove_edge_proxy_endpoint(igniter, path) do
    Igniter.update_elixir_file(igniter, path, fn zipper ->
      remove_plug(zipper, EdgeProxy.Plug.Router)
    end)
  end

  # ------------------------------------------------------------
  # PHOENIX APPS (CONTEXT ONLY)
  # ------------------------------------------------------------

  def inject_edge_context_plug(igniter, path) do
    Igniter.update_elixir_file(igniter, path, fn zipper ->
      if plug_present?(zipper, EdgeContract.Plug) do
        zipper
      else
        insert_after_use(zipper, Phoenix.Endpoint, "plug EdgeContract.Plug")
      end
    end)
  end

  def remove_edge_context_plug(igniter, path) do
    Igniter.update_elixir_file(igniter, path, fn zipper ->
      remove_plug(zipper, EdgeContract.Plug)
    end)
  end

  def inject_liveview_hook(igniter, path) do
    Igniter.update_elixir_file(igniter, path, fn zipper ->
      code = "on_mount {EdgeContract.LiveView, :default}"

      case Function.move_to_defp(zipper, :__using__, 1) do
        {:ok, fn_zipper} ->
          Common.add_code(fn_zipper, code)

        :error ->
          Common.add_code(zipper, code)
      end
    end)
  end

  def inject_socket_context(igniter, path) do
    Igniter.update_elixir_file(igniter, path, fn zipper ->
      case Function.move_to_def(zipper, :connect, 3) do
        {:ok, _existing} ->
          zipper

        :error ->
          code = """
          @impl true
          def connect(_params, socket, connect_info) do
            {:ok, Phoenix.Socket.assign(socket, :edge, connect_info[:edge])}
          end
          """

          Common.add_code(zipper, code)
      end
    end)
  end

  # ------------------------------------------------------------
  # ZIPPER HELPERS
  # ------------------------------------------------------------

  defp insert_after_use(zipper, module_alias, code_string) do
    case move_to_use(zipper, module_alias) do
      {:ok, use_zipper} ->
        Common.add_code(use_zipper, code_string, placement: :after)

      :error ->
        Common.add_code(zipper, code_string)
    end
  end

  defp move_to_use(zipper, module_alias) do
    target_parts = Module.split(module_alias) |> Enum.map(&String.to_atom/1)

    Common.move_to(zipper, fn node ->
      case Zipper.node(node) do
        {:use, _, [{:__aliases__, _, ^target_parts} | _]} -> true
        _ -> false
      end
    end)
  end

  defp plug_present?(zipper, plug_module) do
    target_parts = Module.split(plug_module) |> Enum.map(&String.to_atom/1)

    case Common.move_to(zipper, fn node ->
           case Zipper.node(node) do
             {:plug, _, [{:__aliases__, _, ^target_parts} | _]} -> true
             _ -> false
           end
         end) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp remove_plug(zipper, plug_module) do
    target_parts = Module.split(plug_module) |> Enum.map(&String.to_atom/1)

    case Common.move_to(zipper, fn node ->
           case Zipper.node(node) do
             {:plug, _, [{:__aliases__, _, ^target_parts} | _]} -> true
             _ -> false
           end
         end) do
      {:ok, found_zipper} -> Zipper.remove(found_zipper)
      :error -> zipper
    end
  end
end
