# EdgeProxy Usage, Testing & Operations Guide

This guide covers everything you need to test, operate, monitor, and load-test `ex_edge_proxy`.

---

## 1. Running the ExUnit Test Suite

Run the entire test suite or target individual test files:

```bash
# Run all unit and integration tests
mix test

# Run individual test suites
mix test test/edge_proxy/routing/path_router_test.exs
mix test test/edge_proxy/routing/balancer_test.exs
mix test test/edge_proxy/http/forwarder_test.exs
mix test test/edge_proxy/live_view/session_test.exs
mix test test/edge_proxy/control/security_and_socket_test.exs
mix test test/edge_proxy/control/client_test.exs
mix test test/edge_proxy/resilience_test.exs
mix test test/edge_proxy/telemetry_test.exs
mix test test/edge_proxy/mesh_bridge_test.exs
mix test test/edge_contract/edge_contract_test.exs
mix test test/edge_contract/tenant_enforcer_test.exs
mix test test/mix/tasks/edge_proxy_install_test.exs
```

### What Each Test File Verifies

| Test File | Coverage |
| :--- | :--- |
| `routing/path_router_test.exs` | Exact hosts, `*.mesh.local` wildcards, path prefixes, `x-edge-tenant` header precedence, subdomain tenant extraction, and circuit-breaker blocks. |
| `routing/balancer_test.exs` | Proportional weighted routing (`80/20` split) and automatic failover when an upstream fails health checks. |
| `http/forwarder_test.exs` | End-to-end HTTP `POST` proxying over `Bandit` + `Mint.HTTP`, query string preservation, and `EdgeContract` header injection. |
| `live_view/session_test.exs` | Bidirectional WebSocket frame relaying over `WebSockAdapter` + `Mint.WebSocket` and `503` rejection when circuit breakers are open. |
| `control/security_and_socket_test.exs` | HMAC-SHA256 signatures, 30s timestamp skew window, nonce replay rejection, tenant authorization, and live route mutations. |
| `control/client_test.exs` | `EdgeProxy.Control.Client` HTTP/local commands (`ping`, `put_domain`, `set_circuit_breaker`, `delete_domain`) and invalid secret errors. |
| `resilience_test.exs` | `EdgeProxy.RateLimiter` (`429` + `Retry-After` headers) and `EdgeProxy.HealthChecker` automatic circuit tripping & recovery. |
| `telemetry_test.exs` | Prometheus text exposition output (`GET /metrics`) and optional Bearer token authentication. |
| `mesh_bridge_test.exs` | Optional `Router.Registry` route sync and automatic pruning when mesh nodes disconnect. |
| `edge_contract/*_test.exs` | `EdgeContract.Plug` header parsing, `EdgeContract.LiveView` `:require_tenant` mount guards, and automatic Ecto/Ash tenant isolation. |
| `mix/tasks/edge_proxy_install_test.exs` | Igniter AST transformations, `--generate-gateway`, `--telemetry`, and `uninstall`. |

---

## 2. Igniter Installer CLI (`mix edge_proxy.install`)

```bash
# Wire existing apps only (default behavior)
mix edge_proxy.install

# Scaffold apps/gateway + edge_proxy/routes.json if missing, and wire all Phoenix apps
mix edge_proxy.install --generate-gateway

# Scaffold apps/gateway WITH EdgeProxy.Metrics.Plug (/metrics) included
mix edge_proxy.install --generate-gateway --telemetry

# Customize the generated app name and port
mix edge_proxy.install --generate-gateway --gateway-app edge_gateway --port 8080 --telemetry

# Inject EdgeProxy.Metrics.Plug into an already-existing gateway endpoint
mix edge_proxy.install edge --telemetry

# Uninstall all wiring (and optionally delete generated gateway with --remove-gateway)
mix edge_proxy.install uninstall --remove-gateway
```

---

## 3. Runtime Control Plane (`EdgeProxy.Control.Client` & CLI)

### From Elixir Code

```elixir
# Verify connectivity and HMAC secret
:ok = EdgeProxy.Control.Client.ping(url: "http://gateway:4000/__edge_control__")

# Trip a tenant circuit breaker on a remote gateway
:ok = EdgeProxy.Control.Client.set_circuit_breaker("tenant1", :open, url: "http://gateway:4000/__edge_control__")

# Reset (close) the circuit breaker
:ok = EdgeProxy.Control.Client.set_circuit_breaker("tenant1", :closed, url: "http://gateway:4000/__edge_control__")

# Add a new domain route dynamically
:ok = EdgeProxy.Control.Client.put_domain(
  "reports.mesh.local",
  [%{path: "/", upstream: %{type: "http", host: "10.0.0.5", port: 4003}}],
  url: "http://gateway:4000/__edge_control__"
)

# Delete a domain route
:ok = EdgeProxy.Control.Client.delete_domain("reports.mesh.local", url: "http://gateway:4000/__edge_control__")
```

### From the Command Line (`mix edge_proxy.control`)

```bash
mix edge_proxy.control ping --url http://localhost:4000/__edge_control__
mix edge_proxy.control open-cb tenant1 --url http://localhost:4000/__edge_control__
mix edge_proxy.control close-cb tenant1 --url http://localhost:4000/__edge_control__
mix edge_proxy.control put-domain reports.mesh.local / 127.0.0.1 4003
mix edge_proxy.control delete-domain reports.mesh.local
```

---

## 4. Docker, Prometheus, Grafana & Alertmanager Stack

### Monitoring Directory Structure

```text
monitoring/
├── alertmanager/
│   └── alertmanager.yml                # Webhook routing & alert inhibition rules
├── prometheus/
│   ├── prometheus.yml                  # Scrapes edge_proxy:4000/metrics every 5s
│   └── edge_proxy_alerts.yml           # Alert rules (UpstreamDown, CircuitBreakerOpen, 429s, p95)
└── grafana/
    ├── provisioning/
    │   ├── datasources/
    │   │   └── prometheus.yml          # Auto-wires Prometheus datasource
    │   └── dashboards/
    │       └── default.yml             # Auto-loads EdgeProxy dashboard folder
    └── dashboards/
        └── edge_proxy_dashboard.json   # Pre-built Grafana dashboard JSON
```

### Start the Full Stack

```bash
docker compose up --build -d
```

- **EdgeProxy Gateway:** `http://localhost:4000`
- **Prometheus Metrics Endpoint:** `http://localhost:4000/metrics`
- **Prometheus UI & Alerts:** `http://localhost:9090` (`/alerts`)
- **Alertmanager UI:** `http://localhost:9093`
- **Grafana UI:** `http://localhost:3000` (`admin` / `admin` → **Dashboards → EdgeProxy → EdgeProxy Gateway Overview**)

---

## 5. Multi-Tenant Load & Chaos Simulation

Run `scripts/load_test.exs` to generate concurrent multi-tenant HTTP traffic, `429` rate-limit bursts, and an automated 20-second circuit-breaker trip/recovery cycle:

```bash
# Run 60s load test with 16 concurrent workers + circuit-breaker chaos alert test
mix run scripts/load_test.exs --duration 60 --concurrency 16

# Run load test without tripping circuit breakers
mix run scripts/load_test.exs --duration 30 --concurrency 10 --no-chaos
```
