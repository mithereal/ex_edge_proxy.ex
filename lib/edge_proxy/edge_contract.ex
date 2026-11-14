defmodule EdgeProxy.EdgeContract do
  @moduledoc """
  Shared contract between EdgeProxy and all umbrella apps.
  """

  defstruct [:tenant, :domain, :request_id, :auth_context]

  @type t :: %__MODULE__{
          tenant: String.t() | nil,
          domain: String.t() | nil,
          request_id: String.t() | nil,
          auth_context: map() | nil
        }
end
