# Verificación F2 — Cierre de fase (issue #21)

Estado: **Fases F1 y F2 completadas y verificadas.** Panel de Creador, Capability Tokens opacos con revocación en caliente, módulo multimedia Cloudflare R2 con SigV4 nativo Erlang/OTP y Zero Server Footprint, cifrado AEAD AES-256-GCM, prohibición estricta de `.svg` contra XSS en CEF y validación en vivo en OBS Studio 32.2.2 consolidados en issues #17, #19 y #21 (PRs #18 y #20).

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
| REL-08 | `scripts/load.exs 60` (29-09-2026) | 4.500 eventos emitidos, 45.000/45.000 entregas (100%), 0 errores, p95 49 ms (objetivo <100 ms); RAM BEAM 468 MB → 365 MB |
| DEV-13 | OBS Studio 32.2.2 en vivo (`obs-browser` CEF 152.0.7977.83) | PASS verificado mediante `scripts/test_obs_validation.py`: canal alfa transparente (RGBA=0), tipografía nítida, badges de Twitch/YouTube unificados, reconexión limpia tras ocultar/mostrar fuente y snapshot sin mensajes duplicados |
| DEV-13 | Plataformas reales en vivo | Twitch (chat y metadatos reales de `gilraennr` y `revenant`); YouTube (canal y directo activo de `gilraennr`); Kick diferido |
| COMP-01/10 | Matriz de cumplimiento y plataformas | Actualizado en `docs/compliance.md` y `docs/platforms.md` con justificación formal de diferimiento de Kick |

## 3. Método y límites

ExUnit utiliza fixtures sintéticas, transporte HTTP local, mock de WebSocket y servidores locales de prueba aislados; no contacta APIs externas por defecto. Entorno de validación: Elixir 1.20.4/OTP 29.1 sobre Linux amd64 y contenedor Alpine 3.24.2 endurecido.

- **Carga sintética (REL-08)**: 10 perfiles, 30 fuentes demo, 100 lectores SSE concurrentes, ráfagas de 200 eventos/s durante 10 s y 50 eventos/s durante 50 s adicionales. Se verificó latencia p95 de 49 ms (muy inferior al umbral de 100 ms) y descenso controlado de memoria tras recolección de basura de la VM de Erlang. La prueba de carga de 24 horas permanece pendiente antes de una distribución pública general.
- **Validación en OBS Studio 32.2.2 (DEV-13 / SEC-07)**: ejecutada contra OBS Studio 32.2.2 real en Linux (Wayland) mediante OBS WebSocket v5 (`ws://127.0.0.1:4455`). En F1 (`scripts/test_obs_validation.py`) se verificó la transparencia y reconexión de fuentes. En F2 (`scripts/test_obs_f2.py`) se verificó el ciclo completo de seguridad: rechazo 401 de accesos sin token, admisión 200 con streaming SSE con capability token, revocación en caliente en tiempo real al regenerar tokens y restauración inmediata de servicio, con estricto cumplimiento de CSP mediante hash SHA-256 para el CSS de OBS.
- **Módulo multimedia R2 (SEC-05 / SEC-15)**: generación de URLs prefirmadas SigV4 ejecutada íntegramente en Erlang/OTP nativo (`ChatOverlay.Media.generate_presigned_put_url/5`). Cero paso de bytes por el servidor backend. Cuotas de almacenamiento por perfil enforceadas en memoria y persistidas. Bloqueo determinista de subidas `.svg` para neutralizar vectores XSS en CEF.
- **Diferimiento de Kick**: por directriz del operador Kalista en el issue #15, el conector de Kick se difiere formalmente para evitar la deuda técnica derivada de los frecuentes breaking changes de su API de desarrolladores (4-5 alteraciones en el último año) y de la fricción operativa de su portal de desarrollo. La entrega queda consolidada y certificada sobre Twitch, YouTube y OBS Studio.
