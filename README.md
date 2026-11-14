# EdgeProxy (`ex_edge_proxy`)

A lightweight, BEAM-native reverse proxy, load balancer, and tenant-aware edge gateway for Phoenix umbrella applications.

`EdgeProxy` enforces strict architectural boundaries between your public-facing edge gateway and your internal Phoenix services:

- **Edge Gateway App:** Terminates incoming HTTP and WebSocket/LiveView connections, resolves tenant/host/path routes via an ETS-backed routing table, load-balances across weighted healthy upstreams, enforces per-tenant rate limits and circuit breakers, exposes Prometheus metrics, and injects verified `EdgeContract` headers.
- **Downstream Phoenix Apps:** Consume the `EdgeContract` context (`tenant`, `domain`, `request_id`, `auth_context`) via `EdgeContract.Plug` and `EdgeContract.LiveView`, with optional automatic Ecto and Ash tenant isolation.

---

## Architecture Overview

```text
Client Request (e.g. http://mesh.local)
       │
       ▼
┌──────────────────────────────────────────────────────────┐
│ Edge Gateway App (Bandit on Port 4000)                   │
│  ├─ EdgeProxy.Metrics.Plug   (GET /metrics Prometheus)   │
│  ├─ EdgeProxy.Control.Plug   (POST /__edge_control__)    │
│  ├─ EdgeProxy.MeshBridge     (Optional auto-discovery)   │
│  └─ EdgeProxy.Plug.Router    (HTTP & WebSocket proxy)    │
│       ├─ PathRouter + Weighted Balancer                  │
│       ├─ Per-Tenant RateLimiter & Circuit Breakers       │
│       ├─ Active Upstream HealthChecker                   │
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
│     └─ TenantEnforcer   │       │     └─ TenantEnforcer   │
│        (Ecto / Ash)     │       │        (Ecto / Ash)     │
└─────────────────────────┘       └─────────────────────────┘
```

---

## Key Features

- **Fast ETS Routing:** Lock-free lookups across exact hosts, wildcard subdomains (`*.mesh.local`), path prefixes, regex paths, and tenant rules.
- **Weighted Load Balancing:** Distributes traffic proportionally across multiple upstream targets (`upstreams: [...]`) and automatically skips targets marked unhealthy by `HealthChecker`.
- **HTTP & WebSocket/LiveView Proxying:** Streams HTTP requests via `Mint.HTTP` and relays bidirectional WebSocket/LiveView frames via `Mint.WebSocket` + `WebSockAdapter` with bounded queue backpressure (`@max_queue 200`).
- **Active Upstream Health Checks:** Probes `/health` endpoints periodically and automatically trips per-tenant circuit breakers (`503 Service Unavailable`) when all targets for a route go down.
- **Per-Tenant Rate Limiting:** Lock-free ETS fixed-window counters with customizable per-tenant overrides and `429 Too Many Requests` + `Retry-After` responses.
- **HMAC-Signed Runtime Control Plane:** Hot-reload domains, routes, and circuit breakers via `POST /__edge_control__`, `EdgeProxy.Control.Client`, or `mix edge_proxy.control` with HMAC-SHA256 signatures, 30-second timestamp skew checks, and nonce replay prevention.
- **Prometheus & Grafana Observability:** Built-in `:telemetry` collector exporting request counts, latency histograms, rate-limit hits, circuit-breaker states, and upstream health gauges at `GET /metrics`, complete with Prometheus alerts, Alertmanager routing, and an auto-provisioned Grafana dashboard.
- **Automatic Ecto & Ash Tenant Isolation:** `EdgeContract.TenantEnforcer` automatically invokes `repo.put_tenant/1` and `Ash.set_tenant/1` on every HTTP request and LiveView mount.
- **Optional Service Mesh Bridge:** Automatically syncs dynamic cluster registrations from `:ex_service_mesh_router` (`Router.Registry`) when installed, while remaining zero-overhead when omitted.
- **Igniter Umbrella Installer:** One-command scaffolding and AST wiring via `mix edge_proxy.install`.

---

## Documentation

- **[SETUP.md](SETUP.md)** — Installation, umbrella wiring, `routes.json` schema, and environment configuration.
- **[USAGE.md](USAGE.md)** — Complete guide for running the ExUnit test suite, Igniter CLI flags, runtime control plane (`Client` & `mix edge_proxy.control`), Docker + Prometheus/Grafana/Alertmanager stack, and load/chaos testing.

---

## Quick Start

```bash
mix deps.get
mix edge_proxy.install --generate-gateway --telemetry
mix test
```

## License

MIT
