defmodule EdgeProxy.EdgeContract do
  @moduledoc """
  Shared contract between EdgeProxy and all umbrella apps.
  """

  defstruct [:tenant, :domain, :request_id, :auth_context]
end
