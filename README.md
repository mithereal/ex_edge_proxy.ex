# EdgeProxy (`ex_edge_proxy`)

A lightweight, BEAM-native reverse proxy and tenant-aware edge gateway for Phoenix umbrella applications.

`EdgeProxy` enforces strict architectural boundaries between your public-facing edge gateway and your internal Phoenix applications:

- **Edge Gateway App:** Terminates incoming HTTP and WebSocket/LiveView connections, resolves tenant/host/path routes via an ETS-backed routing table, enforces per-tenant circuit breakers, and injects `EdgeContract` headers.
- **Downstream Phoenix Apps:** Consume the verified `EdgeContract` context (`tenant`, `domain`, `request_id`, `auth_context`) via `EdgeContract.Plug` and `EdgeContract.LiveView` without coupling to routing or proxy logic.

---

## Architecture Overview

```text
Client Request (e.g. http://mesh.local)
       │
       ▼
┌──────────────────────────────────────────────────────────┐
│ Edge Gateway App (Bandit on Port 4000)                   │
│  ├─ EdgeProxy.Control.Plug   (/__edge_control__ updates) │
│  └─ EdgeProxy.Plug.Router    (HTTP & WebSocket proxy)    │
│       ├─ EdgeProxy.Routing.PathRouter (tenant/host/path) │
│       └─ Injects x-edge-tenant, x-edge-domain,           │
│                  x-request-id headers                    │
└──────────────────────────┬───────────────────────────────┘
                           │
         ┌─────────────────┴─────────────────┐
         ▼                                   ▼
┌─────────────────────────┐       ┌─────────────────────────┐
│ Auth App (Port 4001)    │       │ Billing App (Port 4002) │
│  ├─ EdgeContract.Plug   │       │  ├─ EdgeContract.Plug   │
│  └─ EdgeContract.Live   │       │  └─ EdgeContract.Live   │
└─────────────────────────┘       └─────────────────────────┘
```

---

## Features

- **Fast ETS Routing:** Zero-bottleneck lookups across exact hosts, wildcard subdomains (`*.mesh.local`), path prefixes, regex paths, and tenant rules.
- **HTTP & WebSocket/LiveView Proxying:** Streams HTTP traffic and relays bidirectional WebSocket/LiveView frames with bounded queue backpressure.
- **Per-Tenant Circuit Breakers:** Instantly short-circuits failing or suspended tenants with `503 Service Unavailable`.
- **HMAC-Signed Control Plane:** Hot-reload domains, routes, and circuit breakers at runtime via `POST /__edge_control__` protected by HMAC-SHA256 signatures, timestamp skew checks, and nonce replay prevention.
- **Igniter Umbrella Installer:** Automatically wires `EdgeProxy` into your gateway endpoint and injects `EdgeContract` plugs, LiveView `on_mount` hooks, and socket handlers into downstream Phoenix apps.

---

## Installation

Add `:edge_proxy`, `:bandit`, and `:igniter` to your umbrella's root `mix.exs` (or your gateway app's `mix.exs`):

```elixir
defp deps do
  [
    {:edge_proxy, github: "mithereal/ex_edge_proxy.ex"},
    {:bandit, "~> 1.5"},
    {:igniter, "~> 0.5", only: [:dev, :test]}
  ]
end
```

Fetch and compile dependencies:

```bash
mix deps.get
mix compile
```

---

## Automated Wiring (Igniter)

Run the Igniter task from your umbrella root to wire your gateway and downstream Phoenix apps automatically:

```bash
# Install into both the edge gateway app and all downstream Phoenix apps
mix edge_proxy.install

# Or run targeted modes:
mix edge_proxy.install edge       # Wire only the edge gateway endpoint
mix edge_proxy.install apps       # Wire only downstream Phoenix apps
mix edge_proxy.install uninstall  # Remove all EdgeProxy & EdgeContract wiring
```

---

## Manual Gateway Setup

1. **Configure Secrets:** Set `control_secret` and `allowed_control_tenants` in `config/config.exs` and override `control_secret` via environment variables in `config/runtime.exs` for production environments.
2. **Create Gateway Endpoint Plug:** Use `Plug.Builder` in `apps/gateway/lib/gateway/endpoint.ex` to plug `Plug.Logger`, `EdgeProxy.Control.Plug`, and `EdgeProxy.Plug.Router`.
3. **Start Bandit in Supervision Tree:** Launch `Bandit` inside `Gateway.Application` pointing to your endpoint on the designated port (default `4000`).
4. **Define Boot-Time Routes:** Place a `routes.json` file in `edge_proxy/routes.json` at your project root to map tenants, host patterns, paths, and upstream server ports.

---

## Using `EdgeContract` in Downstream Phoenix Apps

- **Controllers & Plugs:** Use `EdgeContract.Plug` to parse incoming `x-edge-*` headers into `conn.assigns.edge` within your controllers.
- **Phoenix LiveView:** Invoke `on_mount {EdgeContract.LiveView, :require_tenant}` or `:default` inside your LiveView modules to populate `socket.assigns.edge`.

---

## Runtime Control Plane API

Send signed JSON commands to `POST /__edge_control__` to update routes or toggle circuit breakers without restarting:

| Command `type` | Required Fields | Description |
| :--- | :--- | :--- |
| `put_domain` | `domain`, `routes` | Adds or replaces routes for an exact domain |
| `put_wildcard` | `pattern`, `routes` | Adds or replaces routes for a wildcard host (e.g. `*.mesh.local`) |
| `delete_domain` | `domain` | Removes all routes matching `domain` |
| `set_circuit_breaker` | `tenant`, `state` (`"open"` \| `"close"`) | Trips or resets the circuit breaker for `tenant` |
| `noop` | — | Health/signature verification check |

### Example: Tripping a Circuit Breaker

You can sign and post payload updates programmatically using `EdgeProxy.Control.Security.sign/1` and an HTTP client like `Req` to toggle states at runtime.

---

## Running Tests

```bash
mix deps.get
mix test
```

## License

MIT
