FROM hexpm/elixir:1.20.4-erlang-29.1-alpine-3.24.2@sha256:b6fda8246507074bd84911c234bfc9b346c391b2be7f9fd275e37d9bc5a049b6 AS build
WORKDIR /build
ENV MIX_ENV=prod
RUN mix local.hex 2.5.1 --force && mix local.rebar rebar3 https://builds.hex.pm/installs/1.18.4/rebar3-3.25.1-otp-28 --sha512 992fd755b7926fae455e5e07d9d195f4d3e7f181609eed1b9cabfe548624df10d148cd4b59bda40bebb185d3d68f9a9fd68a70b294101c8ad9cf0fadcc683d24 --force
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix hex.audit && mix deps.compile
COPY lib lib
COPY priv priv
COPY scripts/inventory.exs scripts/inventory.exs
COPY vendor/licenses vendor/licenses
RUN mix compile --warnings-as-errors && mix run --no-start scripts/inventory.exs /inventory && mix release

FROM build AS validation
ENV MIX_ENV=test
COPY .formatter.exs ./
COPY test test
COPY scripts scripts
RUN mix check

FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
# APK pineados exactos (SUP-03): verificados en el repo v3.24 el 2026-09-21.
# Política de upgrade: si un rebuild falla por pin obsoleto, NO se quita el pin;
# se actualiza a la revisión nueva en PR con justificación, rebuild, re-escaneo
# (audit_image.py) y registro en docs/dependencies.md.
RUN apk add --no-cache \
  ca-certificates=20260909-r0 \
  libstdc++=15.2.0-r5 \
  ncurses-libs=6.6_p20260516-r0 \
  libcrypto3=3.5.8-r0 \
  libssl3=3.5.8-r0
WORKDIR /app
COPY --from=build --chown=65532:65532 /build/_build/prod/rel/chat_overlay ./
COPY mix.lock /app/share/mix.lock
COPY --from=build /inventory /app/share
USER 65532:65532
ENV HOME=/tmp CHAT_BIND=0.0.0.0 CHAT_PORT=4100 RELEASE_DISTRIBUTION=none RELEASE_TMP=/tmp ERL_CRASH_DUMP=/dev/null
EXPOSE 4100
CMD ["/app/bin/chat_overlay", "start"]
