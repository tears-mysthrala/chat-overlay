FROM hexpm/elixir:1.20.5-erlang-29.1.2-alpine-3.24.3@sha256:d4a56ccb80b8aeedcb7d9d4a56b4b5b229ec684aaea537dfac39cd146fb3aea5 AS build
WORKDIR /build
ENV MIX_ENV=prod CHAT_STORAGE=json_demo
RUN mix local.hex 2.5.1 --force && mix local.rebar rebar3 https://builds.hex.pm/installs/1.18.4/rebar3-3.25.1-otp-28 --sha512 992fd755b7926fae455e5e07d9d195f4d3e7f181609eed1b9cabfe548624df10d148cd4b59bda40bebb185d3d68f9a9fd68a70b294101c8ad9cf0fadcc683d24 --force
COPY mix.exs mix.lock ./
COPY config config
COPY scripts/prepare_postgrex.exs scripts/prepare_postgrex.exs
RUN mix deps.get --only prod && mix hex.audit && elixir scripts/prepare_postgrex.exs && mix deps.compile
COPY lib lib
COPY priv priv
COPY scripts/inventory.exs scripts/inventory.exs
COPY vendor/licenses vendor/licenses
RUN mix compile --warnings-as-errors && mix run --no-start scripts/inventory.exs /inventory && mix release

FROM build AS validation
ENV MIX_ENV=test
COPY .formatter.exs ./
COPY test test
COPY test_postgres test_postgres
COPY scripts scripts
# CI runs the suite explicitly after building so failures still produce evidence.
RUN mix format --check-formatted && mix compile --warnings-as-errors

FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
# APK pineados exactos (SUP-03): verificados en el repo v3.24 el 2026-11-07.
# Política de upgrade: si un rebuild falla por pin obsoleto, NO se quita el pin;
# se actualiza a la revisión nueva en PR con justificación, rebuild, re-escaneo
# (audit_image.py) y registro en docs/dependencies.md.
RUN apk add --no-cache \
  ca-certificates=20261020-r0 \
  libstdc++=15.2.0-r5 \
  ncurses-libs=6.6_p20260516-r0 \
  libcrypto3=3.5.9-r0 \
  libssl3=3.5.9-r0 \
  musl=1.2.6-r3 \
  musl-utils=1.2.6-r3 \
  zlib=1.4-r0 \
  # Decisión humana del 2026-11-07 (#50): sin cliente wget en la imagen. El código del applet
  # sigue dentro de /bin/busybox; se retiran el enlace y su ayudante TLS. apk lo instala por
  # install_if, así que se excluye con un conflicto en vez de borrarlo después.
  '!ssl_client' \
 && rm /usr/bin/wget \
 && test ! -e /usr/bin/wget && test ! -e /usr/bin/ssl_client
WORKDIR /app
COPY --from=build --chown=65532:65532 /build/_build/prod/rel/chat_overlay ./
COPY mix.lock /app/share/mix.lock
COPY --from=build /inventory /app/share
USER 65532:65532
ENV HOME=/tmp CHAT_BIND=0.0.0.0 CHAT_PORT=4100 RELEASE_DISTRIBUTION=none RELEASE_TMP=/tmp ERL_CRASH_DUMP=/dev/null
EXPOSE 4100
CMD ["/app/bin/chat_overlay", "start"]
