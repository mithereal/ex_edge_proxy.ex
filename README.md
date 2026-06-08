# EdgeProxy

EdgeProxy is a single-node, LiveView-aware reverse proxy for Phoenix umbrella applications. It routes HTTP and WebSocket (LiveView) traffic across multiple upstream Phoenix apps using deterministic domain + path + tenant resolution.

It is designed to sit in front of one or more Phoenix endpoints and act as a transport-level routing layer.

---

# Overview

EdgeProxy provides:

- HTTP reverse proxy (via Mint)
- LiveView WebSocket proxy (session-based GenServer model)
- Domain-based routing (multi-domain support)
- Wildcard tenant routing (*.myapp.com)
- Path-based routing (/dashboard, /api, etc.)
- Per-tenant circuit breakers
- Runtime routing updates via control plane
- ETS-based hot routing lookup (no per-request DB calls)

---


## Installation 
Use the EdgeProxy installer:

```elixir
mix edge_proxy.install
```


If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `edge_proxy` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:edge_proxy, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/edge_proxy>.

