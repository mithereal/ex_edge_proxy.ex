# EdgeProxy Setup Guide (`SETUP.md`)

This guide covers installing, configuring, and wiring `ex_edge_proxy` into a Phoenix umbrella project—including gateway scaffolding, `EdgeContract` consumption, Ecto/Ash multi-tenancy, optional service mesh discovery, and Prometheus metrics.

---

## 1. Add Dependencies

Add `:edge_proxy`, `:bandit`, and `:igniter` to your umbrella's root `mix.exs` (or your gateway app's `mix.exs`):

```elixir
defp deps do
  [
    {:edge_proxy, ">= 0.0.0"},
    {:bandit, "~> 1.5"},
    {:igniter, "~> 0.5", only: [:dev, :test]},
    # Optional: enable dynamic node discovery via ExServiceMeshRouter
    {:ex_service_mesh_router, ">= 0.0.0"}
  ]
end
```

Fetch and compile dependencies:

```bash
mix deps.get
mix compile
```

---

## 2. Wire Your Umbrella Apps

### Option A: Automated Scaffolding & Wiring (Recommended)

Run the Igniter installer from your umbrella root:

```bash
# Scaffold apps/gateway + edge_proxy/routes.json and wire all downstream Phoenix apps
mix edge_proxy.install --generate-gateway --telemetry

# Or wire existing apps without generating a new gateway
mix edge_proxy.install
```

### Option B: Manual Gateway Wiring

1. **Create `apps/gateway/lib/gateway/endpoint.ex`:**

   ```elixir
   defmodule Gateway.Endpoint do
     use Plug.Builder

     plug Plug.Logger
     plug EdgeProxy.Metrics.Plug
     plug EdgeProxy.Control.Plug
     plug EdgeProxy.Plug.Router
   end
   ```

2. **Start `Bandit` in `apps/gateway/lib/gateway/application.ex`:**

   ```elixir
   defmodule Gateway.Application do
     use Application

     @impl true
     def start(_type, _args) do
       port = String.to_integer(System.get_env("GATEWAY_PORT") || "4000")

       children = [
         {Bandit, plug: Gateway.Endpoint, port: port}
       ]

       opts = [strategy: :one_for_one, name: Gateway.Supervisor]
       Supervisor.start_link(children, opts)
     end
   end
   ```

3. **Wire `EdgeContract` into each downstream Phoenix app:**
   - Add `plug EdgeContract.Plug` inside your downstream `Endpoint` (before `YourAppWeb.Router`).
   - Add `on_mount {EdgeContract.LiveView, :default}` (or `:require_tenant`) inside `live_view/0` in `lib/your_app_web.ex`.

---

## 3. Application Configuration

### `config/config.exs`

```elixir
import Config

config :edge_proxy,
  control_secret: "control_secret",
  allowed_control_tenants: :all,
  # Optional Bearer token for GET /metrics (nil = open)
  metrics_token: nil,
  # :auto (enables if :ex_service_mesh_router is loaded) | true | false
  enable_mesh_bridge: :auto,
  rate_limit: [
    enabled: true,
    max_requests: 120,
    window_seconds: 60,
    tenant_overrides: %{"enterprise_tenant" => 1_000}
  ],
  health_check: [
    enabled: true,
    interval_ms: 5_000,
    timeout_ms: 2_000,
    path: "/health",
    failure_threshold: 3,
    recovery_threshold: 2
  ]
```

### `config/dev.exs` (Internal Upstream Ports)

Bind downstream Phoenix apps to localhost-only ports so they do not collide with the gateway on port `4000`:

```elixir
import Config

config :auth_app, AuthAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  server: true

config :billing_app, BillingAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: true
```

### `config/runtime.exs` (Production Secrets)

```elixir
import Config

if config_env() == :prod do
  control_secret =
    System.get_env("EDGE_CONTROL_SECRET") ||
      raise "environment variable EDGE_CONTROL_SECRET is missing"

  config :edge_proxy,
    control_secret: control_secret,
    metrics_token: System.get_env("EDGE_METRICS_TOKEN")
end
```

---

## 4. Boot-Time Routing Table (`edge_proxy/routes.json`)

Create `edge_proxy/routes.json` in your umbrella root. Routes are evaluated top-to-bottom—place specific path prefixes above catch-all `"/"` routes:

```json
[
  {
    "tenant": "any",
    "host": "*.mesh.local",
    "path": "/billing",
    "upstreams": [
      { "type": "http", "host": "127.0.0.1", "port": 4002, "weight": 80 },
      { "type": "http", "host": "127.0.0.1", "port": 4003, "weight": 20 }
    ]
  },
  {
    "tenant": "any",
    "host": "*.mesh.local",
    "path": "/",
    "upstream": {
      "type": "http",
      "host": "127.0.0.1",
      "port": 4001
    }
  }
]
```

---

## 5. Consuming `EdgeContract` & Multi-Tenancy

### In Phoenix Controllers

```elixir
defmodule BillingAppWeb.InvoiceController do
  use BillingAppWeb, :controller

  def index(conn, _params) do
    %{tenant: tenant, domain: domain, request_id: req_id} = conn.assigns.edge
    json(conn, %{tenant: tenant, domain: domain, request_id: req_id})
  end
end
```

### In Phoenix LiveViews

```elixir
defmodule BillingAppWeb.DashboardLive do
  use BillingAppWeb, :live_view
  on_mount {EdgeContract.LiveView, :require_tenant}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :tenant, socket.assigns.edge.tenant)}
  end
end
```

### Automatic Ecto & Ash Tenant Isolation

Enable automatic `repo.put_tenant/1` and `Ash.set_tenant/1` in `config/config.exs`:

```elixir
config :edge_proxy,
  enable_ecto_tenant: true,
  ecto_repo: MyApp.Repo,
  enable_ash_tenant: true
```

---

## 6. Optional Service Mesh Discovery (`ExServiceMeshRouter`)

If `:ex_service_mesh_router` is included in `deps`, add `Router.Shared.ClusterLifecycleWorker` to each downstream Phoenix app's supervision tree so it automatically announces itself to the gateway:

```elixir
children = [
  MyApp.Repo,
  MyAppWeb.Endpoint,
  {Router.Shared.ClusterLifecycleWorker,
   service_name: "billing.mesh.local",
   ip: "127.0.0.1",
   port: 4002}
]
```

`EdgeProxy.MeshBridge` automatically syncs live entries from `Router.Registry` every 2 seconds and prunes routes when nodes disconnect.

---

## 7. Local Smoke Test

Start your umbrella server (`mix phx.server`) and test routing with `curl`:

```bash
# Route to Auth App (4001) with subdomain tenant extraction
curl -H "Host: tenant1.app.mesh.local" http://localhost:4000/login

# Route to Billing App (4002/4003) with explicit x-edge-tenant header
curl -H "Host: app.mesh.local" -H "x-edge-tenant: tenant1" http://localhost:4000/billing/invoices

# Scrape Prometheus metrics
curl http://localhost:4000/metrics
```
