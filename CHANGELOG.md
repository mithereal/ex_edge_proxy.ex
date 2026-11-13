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
