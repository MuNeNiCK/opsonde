ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.0.6-debian-bookworm-20260824-slim
ARG NODE_IMAGE=node:24.21.0-bookworm-slim
ARG RUNNER_IMAGE=debian:bookworm-slim

FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS assets

WORKDIR /app
COPY assets/package.json assets/pnpm-lock.yaml assets/
RUN corepack enable \
  && cd assets \
  && pnpm install --frozen-lockfile
COPY assets assets
RUN cd assets && pnpm run build

FROM ${ELIXIR_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config/config.exs config/prod.exs config/
RUN mix deps.get --only prod && mix deps.compile

COPY lib lib
COPY priv priv
COPY config/runtime.exs config/
COPY --from=assets /app/priv/static priv/static

RUN mix compile && mix release opsonde_server

FROM ${RUNNER_IMAGE} AS server

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libncurses6 libstdc++6 openssl \
  && rm -rf /var/lib/apt/lists/*

ARG OPSONDE_VERSION=0.1.1
LABEL org.opencontainers.image.title="Opsonde" \
      org.opencontainers.image.version="${OPSONDE_VERSION}"

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000

WORKDIR /app
RUN useradd --create-home --uid 10001 opsonde
COPY --from=builder --chown=opsonde:opsonde /app/_build/prod/rel/opsonde_server ./

USER opsonde
EXPOSE 4000

ENTRYPOINT ["/app/bin/opsonde_server"]
CMD ["start"]
