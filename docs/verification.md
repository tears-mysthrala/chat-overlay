# Verificación F2 — evidencia por candidata

Estado al 02-10-2026: **deuda F2 en curso; no cierre completo ni autorización de
publicación**. El cierre de #21 se conserva debajo como evidencia histórica.
Sus 110 pruebas y OBS 32.2.2 no se atribuyen a los cambios posteriores.

## Evidencia actual

| Candidata | Comando / prueba | Resultado observado | Límite |
| --- | --- | --- | --- |
| #56, `86e0d0a` | `mix check`, pre-push, CI run 36986799200 | 211 pruebas; gates remotos verdes | Atomicidad JSON; no equivalencia RLS |
| #57, `f85882b` | `mix check`, `node --check priv/static/app.js`, pre-push | 234 pruebas, build/smoke/auditoría local pasan | R2 simulado; CI verificar en PR; sin OBS actualizado |
| #40, `3ba84d3` | `mix check`, `test/recovery_test.exs` | 240 pruebas; copia/rotación/restauración sintéticas | No instancia real ni corte eléctrico |
| #33, `aae4519` | carga sintética acotada y evidencia de memoria | Candidata separada; consultar PR #33 | No integrada en esta pila ni ensayo 4/24 h |

El número de pruebas identifica una ejecución y revisión concretas, no un umbral
fijo de calidad. Consultar GitHub para el estado remoto de cada PR antes de merge.
No se atribuye una revisión CodeRabbit completa a un resultado limitado por cuota.

| Requisito/deuda | Evidencia disponible | Estado pendiente |
| --- | --- | --- |
| Persistir antes de confirmar | `profile_persistence_test.exs`, `profile_storage_test.exs` | Revisión #56 y [aceptación #51](workflows/deployment/runs/2026-10-09-persistence-acceptance.md): fallos y reinicio probados, sin fallback JSON |
| Cuota y limpieza | `media_ledger_test.exs`, `web_f2_test.exs` | #57; conciliación/reautenticación/vista operativa #48 |
| Recuperación y clave | `recovery_test.exs`, [runbook](recovery.md) | Revisión #40 y aprobación antes de operación real |
| Aislamiento de almacenamiento SEC-13 | [PostgreSQL local](postgres-storage.md), `test_postgres/rls_test.exs`, boot/restart del producto | ADR0005 implementada; rol/pool y mutaciones reales26 PASS por seed0/424242, boot/restart PASS; separación desplegada en PR67. [Aceptación #51](workflows/deployment/runs/2026-10-09-persistence-acceptance.md). No protege de aplicación totalmente comprometida ni cierra #39/distribución; JSON **no acredita** RLS |
| Formato real SEC-17 | [límites multimedia](media-storage.md) | #49: cuarentena/decoder/salida ligada a hash pendientes |
| ASVS y pruebas negativas | Regresiones existentes; mapa parcial histórico | #42: IDs oficiales/evidencia y revisión de riesgo residual |
| Navegador y OBS | Evidencia histórica #19/#21 | #43: candidata actual, navegador y OBS por separado |
| Publicación | [índice #55](https://github.com/tears-mysthrala/chat-overlay/issues/55) | #4 y gates técnicos/humanos; sin autorización de merge/despliegue |

## Evidencia histórica — cierre #21 (30-09-2026)

Lo siguiente conserva los resultados declarados para aquella entrega; no se ha
repetido en esta revisión ni se extiende a código posterior. Las afirmaciones de
multimedia se limitan a extensión/MIME declarados: no prueban formato real.

## 1. Evidencias de entrega de Fase F2 (issue #21)

| Área / contrato | Evidencia reproducible | Resultado local |
| --- | --- | --- |
| DEV-01/04/16 | `scripts/check_traceability.py`, issues #17, #19, #21 | PASS; ramas `feat/17-*`, `test/19-*`, `docs/21-*` y trazabilidad remota verificadas |
| ARCH-01/SEC-03 | `mix check`: formato, compilación y ExUnit | 110 pruebas PASS (incluye crypto, media, profiles, web, stream, connectors, load); 0 advertencias de compilación (`--warnings-as-errors`) |
| SEC-14 | `test/crypto_test.exs`, `ChatOverlay.Crypto` | Capability Tokens opacos de 32 bytes URL-safe (`generate_capability_token/0`), hashing SHA-256 en reposo (`hash_token/1`), verificación en tiempo constante (`Plug.Crypto.secure_compare/2`) para mitigar ataques de temporización |
| SEC-15 | `test/crypto_test.exs`, `ChatOverlay.Crypto` | Cifrado simétrico autenticado AEAD (AES-256-GCM) nativo OTP (`:crypto.crypto_one_time_aead/6`) para credenciales en reposo, payload versionado (`v1:...`) y IV aleatorio por registro; OAuth 2.0 PKCE (`code_verifier` + `code_challenge` S256) y firmado criptográfico de `state` HMAC-SHA256 con timestamp y expiración anti-CSRF |
| SEC-05 | `test/media_test.exs`, `ChatOverlay.Media` | Módulo multimedia con Cloudflare R2 Presigned URLs SigV4 nativo Erlang/OTP (`:crypto.mac(:hmac, :sha256, ...)`), subida directa desde el navegador (*Zero Server Footprint / Zero Egress Fees*), validación estricta de extensiones y tipos MIME (`.mp3`, `.ogg`, `.wav`, `.webm`, `.webp`, `.png`, `.gif`), cuotas por perfil (por defecto 10 MB) y prohibición estricta de `.svg` (`:svg_prohibited_for_security`) para evitar inyecciones XSS en el motor Chromium/CEF de OBS Studio |
| SEC-06 | `test/media_test.exs`, `ChatOverlay.Net` | Validación y desinfección de URLs externas con comprobación de esquema HTTPS, extensiones permitidas y resolución DNS de IP pública contra SSRF (`ChatOverlay.Net.public_ip?/1`), bloqueando loopback, redes privadas e IPv6 |
| DEV-13 / SEC-07 | OBS Studio 32.2.2 en vivo (`scripts/test_obs_f2.py`) | PASS en vivo en OBS Studio 32.2.2 real (CEF 152.0.7977.83 / Wayland) mediante OBS WebSocket v5: 5 estados verificados con capturas visuales en `artifacts/` (401 sin token, 200 con token streaming SSE, 401 tras revocación en caliente, restauración con nuevo token, fondo transparente RGBA=0). CSP endurecida con hash SHA-256 del CSS inyectado por OBS (`'sha256-Yd1GhiWi47kUsi/SDfKQTY7E39TboDOQOjTJBsT0GQg='`), 0 advertencias en consola CEF y sin `unsafe-inline` |
| PROD-01/SEC-09 | Panel de Creador (`/`, `priv/static/`) | Interfaz de panel con sección de enlace OBS, botón de copia rápida, advertencia de revocación, pestañas de alertas multimedia (URL externa vs Cloudflare R2), reproductor de audio de prueba HTML5 y vista previa de miniaturas de imagen |
| SEC-08 | `scripts/smoke_image.py` | Arranque real no root (UID 65532), raíz de solo lectura, capacidades eliminadas, límites efectivos de CPU/RAM/PID, CSP, readiness y SSE |
| SEC-10 | `scripts/scan_secrets.py` (Gitleaks) | 0 hallazgos de secretos en el repositorio; tokens bearer anonimizados en logs (`token[:12]...`) |
| SUP-02/06 | Hex 2.5.1 y `scripts/inventory.exs` | 0 avisos de seguridad Hex tras actualizar dependencias; inventario con licencias |
| SUP-04 | `scripts/audit_image.py` | CycloneDX 1.7 válido, aplicación + runtime + imagen; componentes inspeccionados |
| SUP-07 | `scripts/audit_image.py` con VEX aprobado | PASS: 0 activos, 4 ignorados en ignoredMatches mediante `vex.openvex.json` (aprobado por Kalista; zlib/busybox sin parche upstream) |

## 2. Histórico de Verificación F1 (issue #15)

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
| REL-08 | `scripts/load.exs 60` (29-09-2026); [registro de carga #34](workflows/deployment/runs/2026-10-09-soak.md) (09-10-2026) | Prueba histórica: 4.500 eventos, 45.000/45.000 entregas, 0 errores, p95 49 ms, RAM BEAM 468 MB → 365 MB. Cuatro horas aceptadas: 7.215.000/7.215.000 entregas, 0 errores, p95 50 ms (objetivo <100 ms), sin OOM y recursos estables en la ventana analizada. Prueba de 24 horas iniciada; resultado y análisis pendientes. |
| DEV-13 | OBS Studio 32.2.2 en vivo (`obs-browser` CEF 152.0.7977.83) | PASS verificado mediante `scripts/test_obs_validation.py`: canal alfa transparente (RGBA=0), tipografía nítida, badges de Twitch/YouTube unificados, reconexión limpia tras ocultar/mostrar fuente y snapshot sin mensajes duplicados |
| DEV-13 | Plataformas reales en vivo | Twitch (chat y metadatos reales de `gilraennr` y `revenant`); YouTube (canal y directo activo de `gilraennr`); Kick diferido |
| COMP-01/10 | Matriz de cumplimiento y plataformas | Actualizado en `docs/compliance.md` y `docs/platforms.md` con justificación formal de diferimiento de Kick |

## 3. Método y límites

ExUnit utiliza fixtures sintéticas, transporte HTTP local, mock de WebSocket y servidores locales de prueba aislados; no contacta APIs externas por defecto. Entorno de validación: Elixir 1.20.4/OTP 29.1 sobre Linux amd64 y contenedor Alpine 3.24.2 endurecido.

- **Carga sintética (REL-08)**: 10 perfiles, 30 fuentes demo, 100 lectores SSE concurrentes, ráfagas de 200 eventos/s durante 10 s y 50 eventos/s durante 50 s adicionales. Se verificó latencia p95 de 49 ms (muy inferior al umbral de 100 ms) y descenso controlado de memoria tras recolección de basura de la VM de Erlang. La prueba de carga de 24 horas permanece pendiente antes de una distribución pública general.
- **Validación en OBS Studio 32.2.2 (DEV-13 / SEC-07)**: ejecutada contra OBS Studio 32.2.2 real en Linux (Wayland) mediante OBS WebSocket v5 (`ws://127.0.0.1:4455`). En F1 (`scripts/test_obs_validation.py`) se verificó la transparencia y reconexión de fuentes. En F2 (`scripts/test_obs_f2.py`) se verificó el ciclo completo de seguridad: rechazo 401 de accesos sin token, admisión 200 con streaming SSE con capability token, revocación en caliente en tiempo real al regenerar tokens y restauración inmediata de servicio, con estricto cumplimiento de CSP mediante hash SHA-256 para el CSS de OBS.
- **Módulo multimedia R2 (SEC-05 / SEC-15)**: generación de URLs prefirmadas SigV4 ejecutada íntegramente en Erlang/OTP nativo (`ChatOverlay.Media.generate_presigned_put_url/5`). Cero paso de bytes por el servidor backend. Cuotas de almacenamiento por perfil enforceadas en memoria y persistidas. Bloqueo determinista de subidas `.svg` para neutralizar vectores XSS en CEF.
- **Diferimiento de Kick**: por directriz del operador Kalista en el issue #15, el conector de Kick se difiere formalmente para evitar la deuda técnica derivada de los frecuentes breaking changes de su API de desarrolladores (4-5 alteraciones en el último año) y de la fricción operativa de su portal de desarrollo. La entrega queda consolidada y certificada sobre Twitch, YouTube y OBS Studio.

## Mapeo ASVS actual (#42)

La [selección ASVS 5.0.0](asvs-f2.md) contrasta IDs y niveles con una revisión fija
del repositorio oficial. Mantiene estados parciales, no validados y pendientes;
no constituye evaluación L2 completa ni autorización de publicación.

### Preparación de evidencia de carga sostenida — issue #4

La herramienta `scripts/load.exs` registra memoria total de BEAM y procesos cada
minuto, duración real e instantes UTC, y admite una etiqueta de revisión del código.
Histograma acotado y percentiles conservadores comprobados por
`test/load_metrics_test.exs`. Metodología y comandos reproducibles en
[scripts/README.md](../scripts/README.md#carga-sostenida-sintética-issue-4-rel-08).
Esta instrumentación no acredita estabilidad por sí sola. La ejecución de cuatro
horas y su análisis de recursos están completados y aceptados en el registro
inferior. La ejecución de 24 horas, su análisis y la aprobación humana de
publicación siguen pendientes bajo #4/#34.

### Carga de cuatro horas — 09-10-2026 (#34)

Aceptada sobre base640ef84: 7.215.000/7.215.000 entregas, cero errores, p95 de50 ms, sin OOM y procesos estables. Análisis de memoria y límites en [registro de carga](workflows/deployment/runs/2026-10-09-soak.md). Ejecución de24 h iniciada; resultado pendiente.
