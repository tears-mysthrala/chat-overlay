# Verificación F1 — Cierre de fase (issue #15)

Estado: **Fase F1 completada y verificada.** Plataformas Twitch y YouTube validadas en vivo; integración en vivo en OBS Studio 32.2.2 verificada de forma automatizada y no destructiva; Kick formalmente diferido por inestabilidad de API upstream (issue #15).

| Área / contrato | Evidencia reproducible | Resultado local |
| --- | --- | --- |
| DEV-01/04/16 | `scripts/check_traceability.py`, issue #15, rama/worktree propio | PASS; issue real y trazabilidad remota verificados |
| ARCH-01/SEC-03 | `mix check`: formato, compilación y ExUnit | 78 pruebas PASS (incluye resolución dinámica, unificación multistream, mitigación de CSRF/Origin y fallbacks); 0 advertencias de compilación (`--warnings-as-errors`) |
| REL-01/02/03 | event/adapters/store/stream tests | Esquema de eventos, Unicode, dedup, borrados, caducidad, filtrado, replay SSE y continuidad de Store sin pérdida de historial |
| REL-04/06 | store/socket/http tests | Límites de historial (100 msgs / 30 min), buffers de replay, tombstones, JSON, frames y límite de cuerpo HTTP (256 KiB) |
| Recuperación | HTTP/source/profiles tests | Caída aislada, reconexión limpia, tareas sin huérfanos, gracia de 60 s sin visores y desvinculación atómica de fuentes offline |
| Protocolos | connectors/resolver/socket tests | YouTube Data API v3 (OAuth y API Key), Twitch EventSub WebSocket + Helix + GraphQL con variables parametrizadas (ARCH-07); Kick diferido |
| SEC-05/07 | Chromium local y OBS Studio | Texto HTML literal sin nodos ejecutables (DOM text nodes), assets locales, fondo transparente, responsive, CSP restrictiva |
| SEC-06 | event tests + Net | Destinos cerrados con validación de IP pública, bloqueo de loopback/red privada/IPv6; TLS verificado en producción |
| SEC-08 | `scripts/smoke_image.py` | Arranque real no root (UID 65532), raíz de solo lectura, capacidades eliminadas, límites efectivos de CPU/RAM/PID, CSP, readiness y SSE |
| SEC-10 | `scripts/scan_secrets.py` (Gitleaks) | 0 hallazgos de secretos en el repositorio |
| SUP-02/06 | Hex 2.5.1 y `scripts/inventory.exs` | 0 avisos de seguridad Hex tras actualizar `mint 1.11.0` y `hpax 1.1.0`; inventario con licencias |
| SUP-04 | `scripts/audit_image.py` | CycloneDX 1.7 válido, aplicación + runtime + imagen; 292 componentes en artefacto inspeccionado |
| SUP-07 | `scripts/audit_image.py` con VEX aprobado | PASS: 0 activos, 4 ignorados en ignoredMatches mediante `vex.openvex.json` (aprobado por Kalista; zlib/busybox sin parche upstream) |
| REL-08 | `scripts/load.exs 60` (29-09-2026) | 4.500 eventos emitidos, 45.000/45.000 entregas (100%), 0 errores, p95 49 ms (objetivo <100 ms); RAM BEAM 468 MB → 365 MB (GC estable sin fugas) |
| DEV-13 | OBS Studio 32.2.2 en vivo (`obs-browser` CEF 152.0.7977.83) | PASS verificado mediante `scripts/test_obs_validation.py`: canal alfa transparente (RGBA=0), tipografía nítida, badges de Twitch/YouTube unificados, reconexión limpia tras ocultar/mostrar fuente y snapshot sin mensajes duplicados |
| DEV-13 | Plataformas reales en vivo | Twitch (chat y metadatos reales de `gilraennr` y `revenant`); YouTube (canal y directo activo de `gilraennr`); Kick diferido |
| COMP-01/10 | Matriz de cumplimiento y plataformas | Actualizado en `docs/compliance.md` y `docs/platforms.md` con justificación formal de diferimiento de Kick |

## Método y límites

ExUnit utiliza fixtures sintéticas, transporte HTTP local, mock de WebSocket y servidores locales de prueba aislados; no contacta APIs externas por defecto. Entorno de validación: Elixir 1.20.4/OTP 29.1 sobre Linux amd64 y contenedor Alpine 3.24.2 endurecido.

Carga sintética (REL-08): 10 perfiles, 30 fuentes demo, 100 lectores SSE concurrentes, ráfagas de 200 eventos/s durante 10 s y 50 eventos/s durante 50 s adicionales. Se verificó latencia p95 de 49 ms (muy inferior al umbral de 100 ms) y descenso controlado de memoria tras recolección de basura de la VM de Erlang.

Validación en OBS Studio (DEV-13): ejecutada contra OBS Studio 32.2.2 real en Linux (Hyprland / Wayland) mediante OBS WebSocket v5 (`ws://127.0.0.1:4455`). La verificación automatizada `scripts/test_obs_validation.py` garantiza un ciclo de vida no destructivo con restauración automática del estado de escena y fuentes en bloques `try...finally`.

Diferimiento de Kick: por directriz del operador Kalista en el issue #15, el conector de Kick se difiere formalmente para evitar la deuda técnica derivada de los frecuentes breaking changes de su API de desarrolladores (4-5 alteraciones en el último año) y de la fricción operativa de su portal de desarrollo. La entrega de F1 queda consolidada y certificada sobre Twitch, YouTube y OBS Studio.
