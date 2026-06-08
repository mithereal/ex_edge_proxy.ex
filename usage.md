To implement EdgeProxy features inside upstream Phoenix umbrella apps, you don’t “rebuild EdgeProxy everywhere” — instead you implement a shared internal contract layer so every app participates in the same routing + LiveView + tenant + control-plane assumptions.

0) Use the EdgeProxy installer:

mix edge_proxy.install

You will be prompted to select:

🎯 FRONT EDGE APP (routing owner)

That app becomes the only proxy entry point.

1) Add a shared Edge contract library

Create:

apps/edge_contract/

This is the only shared dependency between EdgeProxy and Phoenix apps.

All apps depend on this — not EdgeProxy directly.

edge_contract.ex

```elixir
defmodule EdgeContract do
@moduledoc """
Shared immutable contract between EdgeProxy and all umbrella apps.
"""

@enforce_keys [:tenant, :domain, :request_id]
defstruct [:tenant, :domain, :request_id, :auth_context]
end
```

2) EdgeProxy header propagation → Phoenix apps

EdgeProxy forwards identity headers:

x-edge-tenant
x-edge-domain
x-edge-request-id
x-edge-sig (optional)

Phoenix apps ONLY READ THESE VALUES

Injected into every Phoenix endpoint:
```elixir
plug :put_edge_context

defp put_edge_context(conn, _opts) do
tenant = get_req_header(conn, "x-edge-tenant") |> List.first()
domain = get_req_header(conn, "x-edge-domain") |> List.first()

edge = %EdgeContract{
tenant: tenant,
domain: domain,
request_id: get_req_header(conn, "x-edge-request-id") |> List.first()
}

assign(conn, :edge, edge)
end
```

3) Standardized LiveView propagation

Edge-aware LiveView mounts:

```elixir
def mount(_params, session, socket) do
edge =
case session["edge"] do
nil -> nil
map -> struct(EdgeContract, map)
end

{:ok, assign(socket, :edge, edge)}
end
```

Rule:
LiveView does NOT compute tenant
LiveView only consumes EdgeContract

4) Channel protection (required pattern)

Each Phoenix app enforces authorization:

```elixir
def join("room:" <> id, _params, socket) do
tenant = socket.assigns.edge.tenant

if authorized_tenant?(tenant, id) do
{:ok, socket}
else
{:error, :unauthorized}
end
end
```

Key rule:

EdgeProxy filters traffic. Phoenix apps enforce identity + permissions.

5) Edge-aware socket connection

In user_socket.ex:

```elixir
def connect(_params, socket, connect_info) do
edge = connect_info[:edge]

{:ok, assign(socket, :edge, edge)}
end
```

Requirement:

EdgeProxy must inject connect_info[:edge] during WS upgrade.

6) Control-plane compatibility (optional but powerful)

EdgeProxy may broadcast system events:

```elixir
EdgeEvents.broadcast("edge:tenant:acme", {:circuit_breaker, :open})
```
Apps subscribe internally:

```elixir
Phoenix.PubSub.subscribe(MyApp.PubSub, "edge:tenant:" <> tenant)
```

7) Circuit breaker cooperation (soft signal only)

Apps may degrade gracefully:

```elixir
def handle_info(:edge_circuit_open, socket) do
{:noreply, assign(socket, :read_only, true)}
end
```

Important:
EdgeProxy signals state
Apps decide behavior
No enforcement from EdgeProxy

8) HTTP routing compatibility

No structural changes required in Phoenix apps.

Apps should:

trust x-edge-tenant
avoid recomputing tenant from host
treat request as already routed by EdgeProxy
🧱 System Responsibility Model
EdgeProxy (front-edge app only)

Responsible for:

domain routing
tenant selection
websocket/session routing
circuit breaking
traffic shaping
upstream selection
Phoenix umbrella apps

Responsible for:

authentication
authorization
channel rules
business logic
UI rendering
⚠️ Core architectural rule

EdgeProxy decides WHERE traffic goes
Phoenix apps decide WHAT is allowed

Minimal Edge-aware umbrella checklist

Every Phoenix app must:

✔ accept x-edge-tenant
✔ accept x-edge-domain
✔ attach EdgeContract to conn/socket
✔ enforce channel authorization using tenant
✔ tolerate circuit-breaker signals
✔ never derive tenant from host headers

Final system result

After installation:

EdgeProxy app (single)
↓ routes + shapes traffic

Phoenix apps (many)
↓ consume EdgeContract only
↓ enforce rules locally