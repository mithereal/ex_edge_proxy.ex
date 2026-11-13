# ============================================================
# Stage 1: Build Release
# ============================================================
FROM hexpm/elixir:1.16.3-erlang-26.2.5-alpine-3.19.1 AS build

RUN apk add --no-cache build-base git

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY lib lib
COPY edge_proxy edge_proxy

RUN mix compile

COPY config/runtime.exs config/
RUN mix release

# ============================================================
# Stage 2: Minimal Runtime Image
# ============================================================
FROM alpine:3.19.1 AS app

RUN apk add --no-cache libstdc++ openssl ncurses-libs curl

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"
ENV GATEWAY_PORT="4000"

COPY --from=build --chown=nobody:root /app/_build/${MIX_ENV}/rel/edge_proxy ./
COPY --from=build --chown=nobody:root /app/edge_proxy ./edge_proxy

USER nobody

EXPOSE 4000

CMD ["/app/bin/edge_proxy", "start"]
