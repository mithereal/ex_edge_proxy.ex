# Changelog

## v0.1.0 (2026-11-13)

### Initial Release
- **Core Reverse Proxy:** Added `EdgeProxy` and `EdgeProxy.Plug.Router` with full HTTP forwarding (`Mint.HTTP`) and bidirectional WebSocket/LiveView proxying (`Mint.WebSocket` + `WebSockAdapter`).
- **ETS Routing & Load Balancing:** Added `EdgeProxy.Routing.Runtime`, `PathRouter`, and `Balancer` supporting exact hosts, wildcard subdomains, path prefixes, and weighted upstream pools.
- **Resilience:** Added lock-free ETS per-tenant rate limiting (`EdgeProxy.RateLimiter`) and active upstream health probing with automatic circuit tripping (`EdgeProxy.HealthChecker`).
- **HMAC Control Plane:** Added `POST /__edge_control__`, `EdgeProxy.Control.Client`, and `mix edge_proxy.control` with HMAC-SHA256 signatures, 30-second skew checks, and nonce replay protection.
- **Observability:** Added `:telemetry` collector and Prometheus exposition endpoint (`GET /metrics`).
- **Downstream App Contract:** Added `EdgeContract.Plug`, `EdgeContract.LiveView`, and `EdgeContract.TenantEnforcer` (Ecto & Ash multi-tenancy).
- **Igniter Installer:** Added `mix edge_proxy.install` with `--generate-gateway` and `--telemetry` flags.

### Added
- **Internal Backplane Client (`EdgeProxy.BackplaneClient`):** Added a zero-dependency `Mint.HTTP` and `Jason` client for internal service-to-service communication over `ex_service_mesh_router` (`x-backplane-service`), automatically forwarding `EdgeContract` context headers (`x-edge-tenant`, `x-edge-domain`, `x-request-id`) from `Plug.Conn`, LiveView sockets, or explicit options.
- **Public Ingress Guard (`EdgeProxy.Plug.InternalGuard`):** Added an edge Plug that blocks external requests targeting internal-only host patterns (defaulting to `*.internal.mesh.local` and `*.internal.zone`) or carrying spoofed `x-backplane-service` headers with `403 Forbidden`.
- **Automatic Backplane Listener (`EdgeProxy.Application`):** Added release-safe (`@env Mix.env()`) auto-boot support for `Router.Router` on loopback (`127.0.0.1:4040` by default) when `:ex_service_mesh_router` and `:bandit` are available (`:enable_mesh_backplane`).
- **ExUnit Test Coverage:** Added unit and integration test suites for `EdgeProxy.BackplaneClient`, `EdgeProxy.Plug.InternalGuard`, and `EdgeProxy.MeshBridge`.

### Changed
- **Internal Service Filtering in `EdgeProxy.MeshBridge`:** Updated registry sync to exclude services matching `:internal_host_patterns` or marked `internal: true` from being exposed on public EdgeProxy ingress, and added route-hash change detection (`phash2`) to skip redundant `EdgeProxy.Routing.Runtime` updates.
- **Consolidated `EdgeProxy.call/2` Pipeline:** Merged duplicate `call/2` clauses in `EdgeProxy` so `InternalGuard`, `RateLimiter`, and `Telemetry` execute in a single unified request lifecycle.
- **HexDocs Module Grouping (`mix.exs`):** Added `EdgeProxy.Plug.InternalGuard` and `EdgeProxy.BackplaneClient` to `docs/0` module groups.

