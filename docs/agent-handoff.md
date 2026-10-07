# Handoff F2 — issue #17 (Panel de Creador, Capability Tokens, Módulo Multimedia R2 y URLs Externas)

> 07-10-2026: ADR0008/#39 implementado en `security/39-private-custodian`,
> PR #67 abierta y enlazada. 327 ExUnit PASS por seed; PostgreSQL 26 PASS por
> seed más boot/persistencia/reinicio; smoke release, 12 Python Linux y separación
> sintética de dos releases PASS. La revisión oficial de la candidata y su delta
> no reportó vulnerabilidades confirmadas; las regresiones OAuth/media se
> corrigieron con pruebas mTLS. Los diez checks de CI pasan en `2e96ed3`.
> CodeRabbit revisó ese delta y solicitó dos correcciones documentales, atendidas
> en esta actualización. Siguiente paso: comprobar CI y la revisión de este
> ajuste; resolver cualquier hallazgo antes del merge y del corte a producción.
> El corte sigue pendiente de verificar firewall y OAuth/OBS/multimedia reales
> en Benten. No se declara acreditada la separación en producción.
> Detalle: docs/workflows/deployment/runs/2026-10-07-private-custodian.md.

> 07-10-2026: preview manual #64 implementado en feat/64-obs-preview y desplegado
> en Benten9502 por aprobación explícita. Runtime43ed8a7a, 295 ExUnit PASS,
> revisión oficial OpenAI e28c1e39 completada sin vulnerabilidades del diff.
> PNG visto en OBS y refresh inmediato sin replay PASS. Audio audible confirmado
> por el operador. Revocación antigua401 y recuperación con enlace nuevo PASS.
> CI/publicación/merge pendientes; no equivale a cierre global de F2.
> Detalle: docs/workflows/deployment/runs/2026-10-07-obs-preview.md.

> Estado actual 02-10-2026: F2 en cierre de deuda (#55), sin merge/despliegue.
> Las secciones iniciales son historial. Consultar las entradas fechadas al final
> y `docs/verification.md`; SEC-13/SEC-17 no están acreditados.

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/17
- Rama: `feat/17-creator-auth-r2-media`
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/17-creator-auth-r2-media`
- Autorizado: Implementación completa de la Fase F2 (ADR 0003, contrato WHAT_WE_ARE_BUILDING.md v1.2) aprobada por el operador Kalista en issue #17.

## Resumen del estado de entrega de Fase F2:

1. **Capa Criptográfica y Seguridad de Tokens (`ChatOverlay.Crypto`)**:
   - Generación de **Capability Tokens** opacos de 32 bytes URL-safe no rellenados para fuentes de navegador de OBS Studio (`generate_capability_token/0`).
   - Hashing SHA-256 (`hash_token/1`) y verificación en tiempo constante (`Plug.Crypto.secure_compare/2`) para mitigar ataques de temporización (SEC-14).
   - Cifrado simétrico autenticado **AEAD (AES-256-GCM)** (`encrypt_aead/3`, `decrypt_aead/3`) utilizando funciones nativas de Erlang/OTP `:crypto.crypto_one_time_aead/6` para credenciales en reposo, con payload versionado (`v1:...`) y IV aleatorio por registro (SEC-15).
   - Flujo OAuth 2.0 PKCE (`code_verifier` + `code_challenge` S256) y firmado criptográfico de parámetro `state` con HMAC-SHA256 y expiración temporal anti-CSRF.
   - 10/10 pruebas unitarias en `test/crypto_test.exs`.

2. **Módulo Multimedia y Presigned URLs SigV4 (`ChatOverlay.Media`)**:
   - Validación estricta de extensiones y MIME:
     - Audios: `.mp3`, `.ogg`, `.wav`, `.webm` (límite: 2 MB por archivo).
     - Imágenes/emojis: `.webp`, `.png`, `.gif` (límite: 512 KB por archivo).
     - **Prohibición estricta de `.svg`** (`:svg_prohibited_for_security`) para evitar inyecciones XSS en el motor Chromium CEF de OBS Studio (SEC-05).
   - Generación de **Presigned PUT URLs** compatibles con AWS SigV4 y Cloudflare R2 implementada 100% con primitivas nativas de Erlang/OTP (`:crypto.mac(:hmac, :sha256, ...)`), sin dependencias externas pesadas de SDKs.
   - Cero custodia y cero transferencia en el servidor (*Zero Server Footprint / Zero Egress Fees*): el navegador del creador sube el archivo directamente a Cloudflare R2 sin que los bytes transiten por el nodo Elixir.
   - Validación y desinfección de URLs externas con comprobación de esquema HTTPS, extensiones permitidas y resolución DNS de IP pública contra SSRF (`ChatOverlay.Net.public_ip?/1`).
   - Control y cumplimiento de cuota de almacenamiento por creador (por defecto 10 MB).
   - 9/9 pruebas unitarias en `test/media_test.exs`.

3. **Ciclo de Vida de Perfiles y Persistencia (`ChatOverlay.Profiles`, `ChatOverlay.Config`)**:
   - Ampliación del esquema de perfil con campos F2: `capability_token_hash`, `media` (`alert_sound`, `alert_image`), `can_upload`, `storage_quota_bytes` y `storage_used_bytes`.
   - Soporte GenServer serializado para:
     - `regenerate_capability_token/1`: regenera token, calcula hash, persiste en JSON y devuelve nuevo enlace.
     - `verify_capability_token/2`: valida acceso. Compatible hacia atrás con perfiles sin token previo (modo transición).
     - `update_media/2`: actualiza y limpia configuración de alertas de sonido e imagen.
     - `update_upload_quota/2`: incrementa/decrementa el uso de disco del perfil acotado a >= 0.
   - Enmascaramiento de seguridad: `Profiles.list/0` y `get/1` exponen `has_capability_token: boolean`, nunca el hash del token en plano.
   - 6/6 pruebas unitarias en `test/profiles_f2_test.exs`.

4. **Protección de Enlaces OBS y Endpoints API (`ChatOverlay.Web`, `ChatOverlay.Stream`)**:
   - `GET /overlay/:handle`: valida `token` en query param; responde 401 Unauthorized HTML con CSP si falta o es inválido.
   - `GET /events/:handle?view=overlay`: valida `token` antes de admitir visor SSE; responde 401 si no está autorizado.
   - `POST /api/profiles/:handle/token/regenerate`: endpoint protegido por origen que genera y devuelve nuevo enlace de OBS.
   - `POST /api/media/presign`: endpoint protegido por origen que valida cuota y genera URL firmada de subida a R2.
   - `POST /api/profiles/:handle/media`: endpoint para guardar URLs y orígenes de audio/imagen.
   - 7/7 pruebas de integración en `test/web_f2_test.exs`.

5. **Panel de Creador y Frontend (`priv/static/index.html`, `app.js`, `app.css`)**:
   - Sección dedicada «Enlace para OBS Studio» con visualización del capability token, botón de copia rápida y advertencia clara antes de regenerar.
   - Sección «Alertas y Efectos Multimedia» con pestañas para alternar entre enlace externo y subida directa a R2.
   - Reproductor integrado de prueba de sonido («Probar sonido») mediante HTML5 Audio.
   - Vista previa inmediata de miniaturas de emoji/imagen con bloqueo proactivo de archivos `.svg`.
   - Política de Seguridad de Contenido (CSP) ajustada en `ChatOverlay.HTTP` permitiendo `media-src 'self' https: data:`, `connect-src 'self' https:` y `img-src 'self' https://static-cdn.jtvnw.net https: data:`.

6. **Verificación y Calidad de Código**:
   - Suite completa ExUnit: **110/110 pruebas PASS** en 8.1s, con 0 advertencias de compilación (`--warnings-as-errors`).
   - Verificación de formato: `mix format --check-formatted` PASS.
   - Trazabilidad: `python3 scripts/check_traceability.py` PASS (`tears-mysthrala/chat-overlay#17; feat/17-creator-auth-r2-media`).
   - Detección de secretos: `python3 scripts/scan_secrets.py` PASS (0 fugas).
   - Análisis estático de seguridad: `python3 scripts/security_static.py` PASS (0 hallazgos).
   - Construcción de imagen Docker: compilación limpia en Alpine 3.24.2 / Elixir 1.20.4.
   - Smoke tests de release: `python3 scripts/smoke_image.py` PASS.
   - Auditoría SBOM y vulnerabilidades: `python3 scripts/audit_image.py` PASS (0 vulnerabilidades accionables en Grype).

7. **Estado de Pull Request y CI (Fase F2 Core)**:
   - Pull Request: https://github.com/tears-mysthrala/chat-overlay/pull/18 (MERGED a `main` en `0ccae4b`, Closes #17).
   - CI en GitHub Actions: **100% PASS** (`CI/source-and-tests` exitoso en 1m18s, `CI/image-security` exitoso en 1m56s).

8. **Validación en Vivo en OBS Studio 32.2.2 (Issue #19, PR #20)**:
   - Issue: https://github.com/tears-mysthrala/chat-overlay/issues/19
   - Pull Request: https://github.com/tears-mysthrala/chat-overlay/pull/20 (MERGED a `main` en `da9d911`, Closes #19).
   - Rama: `test/19-obs-f2-validation`
   - Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/19-obs-f2-validation`
   - Script automatizado vía OBS WebSocket (puerto 4455): `scripts/test_obs_f2.py`.
   - Pruebas superadas en vivo en OBS Studio 32.2.2 (CEF 152.0.7977.83 / Wayland):
     1. **Rechazo 401 Unauthorized sin token**: Verificado en OBS Browser Source. El overlay devuelve 401 con pantalla de aviso amigable y CSP intacta (`obs_f2_401_unauthorized.png`).
     2. **Acceso autorizado 200 OK con Capability Token**: OBS conecta al stream SSE y renderiza el chat en directo de Twitch con badges, timestamps y sanitización XSS (`obs_f2_authorized_live.png`).
     3. **Rechazo de nueva conexión tras revocación**: Al regenerar el capability token mediante `/api/profiles/:handle/token/regenerate`, el token anterior queda invalidado en el backend; cualquier recarga o nueva conexión de OBS Browser Source es rechazada con 401 (`obs_f2_revoked_401.png`). Nota: la desconexión activa forzada de sockets/conexiones SSE ya abiertas al momento de revocar se abordará como mejora en una unidad separada.
     4. **Restauración con nuevo token**: Al actualizar la fuente en OBS con el nuevo token generado, el overlay reanuda la conexión SSE sin reiniciar el proceso ni perder el estado del canal (`obs_f2_restored_live.png`).
     5. **Lienzo completo y transparencia**: Verificado sobre escena con fondo sólido (`TestColor`); la transparencia del overlay es total y el texto se dibuja sin halos ni recortes (`obs_f2_scene_full.png`).
     6. **Panel de Creador (Chromium headless)**: Captura completa del panel con gestión de enlace OBS, advertencia de regeneración y pestañas de alertas multimedia R2 (`dashboard_f2_full.png`).
   - **Ajustes de CSP aplicados**:
     - Sustituido estilo inline en la página de error 401 por hoja de estilo `app.css` y clase `.unauthorized-body` (evitando violación de `style-src`).
     - Añadido el hash `sha256-Yd1GhiWi47kUsi/SDfKQTY7E39TboDOQOjTJBsT0GQg=` a `style-src` en `ChatOverlay.HTTP` para autorizar de forma estricta el CSS inyectado por defecto por OBS Studio sin relajar la directiva a `unsafe-inline`.

9. **Cierre Formal de Fase F2 (Issue #21)**:
   - Issue: https://github.com/tears-mysthrala/chat-overlay/issues/21
   - Pull Request: https://github.com/tears-mysthrala/chat-overlay/pull/22 (MERGED a `main` en `bab387b`, Closes #21).
   - Rama: `docs/21-f2-closure`
   - Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/21-f2-closure`
   - Estado: Consolidación documental y certificación de cierre de Fase F2 aprobada por el operador Kalista el 30-09-2026.
   - Matrices de verificación (`docs/verification.md`), operación (`docs/operations.md`), cumplimiento (`docs/compliance.md`), contrato (`WHAT_WE_ARE_BUILDING.md`) y `README.md` actualizadas con las evidencias completas de F2.

10. **Flujo Interactivo OAuth 2.0 PKCE para Vinculación de Cuentas (Issue #23)**:
   - Issue: https://github.com/tears-mysthrala/chat-overlay/issues/23
   - Rama: `feat/23-oauth-account-linking`
   - Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/23-oauth-account-linking`
   - Implementación:
     - `ChatOverlay.OAuth`: soporte de flujo OAuth 2.0 PKCE (RFC 7636) para Twitch y YouTube. Generación de URLs de autorización con `code_challenge_method=S256` y state cifrado simétricamente con AEAD (AES-256-GCM) conteniendo el `code_verifier`, handle, proveedor y timestamp (Stateless PKCE anti-tamper y anti-replay).
     - Intercambio de código por tokens con destinos autorizados en `ChatOverlay.Net` (`oauth2.googleapis.com` añadido al allowlist de hosts TLS bajo SEC-06).
     - Cifrado de credenciales en reposo mediante AEAD AES-256-GCM en `ChatOverlay.Profiles.link_account/4` bajo SEC-15.
     - Sanitización estricta: `Profiles.list/0` y `get/1` eliminan `encrypted_tokens` y exponen únicamente metadatos públicos (`linked: true`, `username`, `linked_at`).
     - Endpoints en `ChatOverlay.Web`: `GET /api/oauth/authorize/:provider`, `GET /oauth/callback/:provider` y `POST /api/profiles/:handle/unlink/:provider` protegido por origen anti-CSRF.
     - Interfaz de usuario en Panel de Creador (`priv/static/index.html`, `app.js`, `app.css`) con tarjetas para Twitch y YouTube, estados de conexión en vivo y desvinculación interactiva.
     - 126/126 tests PASS en ExUnit (16 tests nuevos en `oauth_test.exs`, `profiles_oauth_test.exs` y `web_oauth_test.exs`).





11. **Ciclo de Vida, Renovación Automática y Rotación Concurrente de Tokens OAuth (Issue #25)**:
    - Issue: https://github.com/tears-mysthrala/chat-overlay/issues/25
    - Rama: `feat/25-token-lifecycle-refresh`
    - Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/25-token-lifecycle-refresh`
    - Alcance y Arquitectura:
      - Este PR introduce la **infraestructura de renovación bajo demanda y coordinación concurrente** (`ChatOverlay.Tokens.get_access_token/3`). Los conectores de streaming actuales (Twitch IRC / YouTube Polling) continúan leyendo credenciales estáticas de entorno/configuración en esta fase; su migración al coordinador `ChatOverlay.Tokens` se realizará en la Fase F3.
    - Implementación y Robustez (feedback incorporado):
      - `ChatOverlay.OAuth.refresh_tokens/3`: soporte para refresco de tokens OAuth para Twitch y Google/YouTube. Parser unificado estricto para transporte real y mocks que exige `access_token` binario no vacío y duración positiva (`expires_in > 0`), rechazando payloads `{}` o malformados con `{:error, :invalid_token_payload}`. Mapeo específico de respuestas de error de Twitch `400 / Bad Request / Invalid refresh token` a `{:error, :invalid_grant}`.
      - `ChatOverlay.Profiles`:
        - Versionado de vinculación anti-carreras (`account_version`): si un refresco de la cuenta A finaliza tras haber vinculado la cuenta B, se detecta el desajuste de versión y se aborta con `{:error, :stale_binding}`, evitando que las credenciales de A sobreescriban a B.
        - Persistencia atómica previa a mutación de memoria: `persist_profiles` se ejecuta antes de modificar `Application.put_env`, impidiendo que fallos de disco dejen memoria y almacenamiento desincronizados.
        - Preservación automática de `refresh_token` existente cuando el proveedor omite devolverlo (Google OAuth) y soporte de rotación cifrado con AEAD AES-256-GCM (`v1:...`).
        - Recuperación fail-closed ante fallo de persistencia durante rotación: si el proveedor rota el token pero el disco no puede escribirse, la cuenta se marca inmediatamente como `reauth_required` (`persistence_failure_during_rotation`) para alertar al usuario y evitar bucles infinitos con credenciales no persistidas.
        - Invalidación de caché en todos los eventos del ciclo de vida: desvinculación (`unlink_account`), vinculación (`link_account`), eliminación de perfil (`delete`) y marcado de reautenticación (`mark_account_reauth_required`).
      - `ChatOverlay.Tokens`: GenServer coordinador concurrente (SEC-15). Protección anti-stampede (agrupación de múltiples llamadas simultáneas en 1 única petición remota), caché en memoria con invalidación selectiva, renovación proactiva ante expiración próxima (< 300s) y propiedad/cancelación de workers de fondo al terminar el coordinador.
      - Supervisión en `ChatOverlay.Application`: integrado en la estrategia `:rest_for_one` tras `ChatOverlay.Profiles`.
      - Interfaz de usuario en Panel de Creador (`priv/static/app.js`, `priv/static/app.css`): badge de estado amarillo «Reautenticación requerida», aviso explícito y botón «Reconectar» para Twitch y YouTube.
      - 150/150 tests PASS en ExUnit (incluyendo regresiones exhaustivas de carreras entre vinculaciones concurrentes, fallo de disco, respuestas malformadas, revocación e invalidación de caché).

12. **Estado del Backlog de Endurecimiento Fase F2**:
    - [x] Clave de cifrado OAuth obligatoria en producción (SEC-15) — completada en Issue #28 / PR #29.
    - [x] Desconexión activa y cierre forzado de visores SSE ante revocación de capability token (SEC-09) — completada en Issue #28 / PR #29.
    - [x] Autenticación de sesión en Panel de Creador y autorización por perfil (SEC-12, SEC-14, ADR-0003) — completada en Issue #30 / PR #31.
    - [ ] Aplicación efectiva de permisos y cuotas de subida en Cloudflare R2 (SEC-05, SEC-17) — pendiente para Unidad siguiente.

## CI hardening — issue #27, same branch and PR #26

Operator explicitly requested reuse of AGY's `feat/25-token-lifecycle-refresh`
worktree and PR #26. Starting commit: `8ef5838`; initial suite: 150 passing tests.
No production code, new dependencies, branch protection, merge or deployment changed.

Added deterministic lifecycle regression tests, offline serial/concurrent full-suite
runs, ExUnit JSON evidence validation (no failures/skips/exclusions/empty suites),
validator tests, bounded Docker execution and a final `quality-gate`. CI triggers
are PR/manual/weekly and obsolete executions are cancelled.

Local verification: both seeds discover 153 tests, with 150 passing and the same
three failures: pending-worker invalidation, ownership after abrupt coordinator
death, and stale binding rejection after unlink/relink. These failures block
acceptance and must be fixed; they are not waived. Python validator tests pass,
as do format, static checks and JavaScript syntax. OBS/upstream/load-long-run tests
were not repeated. The final required-check setting still needs operator action.

Next action: fix the three lifecycle failures and run `MIX_ENV=test sh scripts/ci_tests.sh`
plus `python3 scripts/check_test_report.py output/tests/exunit-0.json output/tests/exunit-424242.json`.
Review the remote CI evidence before approving merge. Rollback: revert the CI commit.

Publishing exception: the pre-push hook's green-test requirement is bypassed solely
to publish intentionally failing regression gates on the existing review PR. This
is the documented scripts/README.md exception; format, workflow lint, static
checks and secret scan were executed. Remote tests remain active and merge is
blocked. No failing test was skipped or represented as passing.

Offline validation exposed two pre-existing media tests that resolved external DNS.
Their successful URL fixtures now use literal public IPv4 addresses; no DNS
validation is disabled and no HTTP request is made. Targeted media/web tests: 16 PASS.

## CI hardening gate resolution — issue #25, issue #27

The three lifecycle regression gate failures identified under CI hardening have been completely resolved:
1. **Pending-worker invalidation**: `Tokens.handle_call({:invalidate, ...})` detects active refresh workers for the target key, terminates them (`Process.exit(pid, :shutdown)`), demonitors/unlinks, and responds to all pending callers with `{:error, :binding_invalidated}`.
2. **Abrupt coordinator death ownership**: `Tokens` coordinator now traps exits (`Process.flag(:trap_exit, true)`) and links spawned workers via `Process.link(pid)`. When coordinator is abruptly killed (`:kill`), the VM's link exit propagation terminates workers immediately regardless of transport blocking. Linked exits from workers are trapped safely without killing the coordinator.
3. **Stale binding rejection across unlink/relink**: `Profiles.do_link_account/4` generates `account_version` using `max(prev_version + 1, System.unique_integer([:positive, :monotonic]))`, guaranteeing that re-linking an account never reuses prior generation IDs, even after an unlink.

Local verification:
- `MIX_ENV=test sh scripts/ci_tests.sh`: Seed 0 (serial) 153/153 PASS; Seed 424242 (concurrent) 153/153 PASS (0 failures, 0 skipped, 0 excluded).
- `python3 scripts/check_test_report.py output/tests/exunit-0.json output/tests/exunit-424242.json`: PASS (2 complete runs, 153 tests each, no omissions).
- `mix compile --warnings-as-errors`: PASS (0 warnings).
- `mix format --check-formatted`: PASS.
- `python3 scripts/security_static.py`: PASS (0 findings).
- `python3 scripts/scan_secrets.py`: PASS (no leaks found).
- `python3 scripts/check_traceability.py`: PASS.

## Desconexión activa de visores SSE y clave de cifrado obligatoria en producción — issue #28

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/28
- Rama: `feat/28-sse-revocation-crypto-key`
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/28-sse-revocation-crypto-key`

### Alcance e Implementación:
1. **Desconexión activa forzada de visores SSE ante revocación de Capability Token (SEC-09)**:
   - Registro concurrente en supervisión: `ChatOverlay.SSERegistry` añadido al árbol de supervisión con `{Registry, keys: :duplicate, name: ChatOverlay.SSERegistry}` para rastrear múltiples visores SSE activos simultáneos (`/events/:handle?view=overlay`) por handle.
   - En `ChatOverlay.Stream.call/2`, las conexiones de tipo overlay purgan notificaciones pendientes (`flush_stale_revocations/0`), registran su PID en `ChatOverlay.SSERegistry` y re-verifican el capability token para cerrar ventanas de carrera durante el handshake.
   - **Limpieza en HTTP/1.1 keep-alive:** En la cláusula `after` de `call/2`, se ejecuta explícitamente `Registry.unregister(ChatOverlay.SSERegistry, handle)` garantizando que cuando Bandit mantiene el proceso socket vivo para servir subsiguientes peticiones HTTP/1.1, la entrada del registro sea eliminada en todas las salidas del `try` (incluyendo rechazos 401 y desconexiones de stream).
   - **Correlación por handle:** `ChatOverlay.Stream.disconnect_viewers/1` despacha `{:capability_token_revoked, handle}` a todos los visores registrados para ese handle. En `poll/6`, se hace match exclusivo con `{:capability_token_revoked, ^handle}`, descartando mensajes tardíos de peticiones anteriores sobre la misma conexión keep-alive.
   - En `ChatOverlay.Stream.poll/6`: al recibir la revocación del handle correspondiente, emite inmediatamente un fragmento SSE `event: error\ndata: {"error":"unauthorized","message":"Capability token revoked"}\n\n` y finaliza la conexión chunked, liberando recursos (`Admission.release/0`).
   - Invocación garantizada en `ChatOverlay.Profiles`:
     - `do_regenerate_capability_token/1`: tras persistir el nuevo token y hash, ejecuta `ChatOverlay.Stream.disconnect_viewers(handle)`.
     - `delete/1`: tras persistir la eliminación e invalidar credenciales, ejecuta `ChatOverlay.Stream.disconnect_viewers(handle)`.
2. **Validación estricta de clave de cifrado en producción y Compose (SEC-15)**:
   - En `ChatOverlay.OAuth`:
     - `validate_encryption_key/1`: en entornos de producción (`MIX_ENV=prod` o release binaria activa vía `RELEASE_NAME`), valida obligatoriamente que la clave de cifrado (`CHAT_ENCRYPTION_KEY` o `:encryption_key`) esté configurada, sea binaria, no esté vacía, sea distinta a la clave por defecto de desarrollo (`chat_overlay_secret_key_32_bytes!`) y tenga una longitud mínima de 32 bytes.
   - En `ChatOverlay.Application.start/2`:
     - Realiza `ChatOverlay.OAuth.validate_encryption_key()` antes del arranque del árbol de supervisión y falla de inmediato (`raise "Invalid encryption key configuration: ..."`) si las condiciones de producción no se cumplen (fail-closed).
   - En `compose.yaml`:
     - `CHAT_ENCRYPTION_KEY` requerida mediante interpolación `${CHAT_ENCRYPTION_KEY:?...}`, fallando de inmediato con un mensaje descriptivo que instruye cómo generarla si no se provee.
   - En `README.md`:
     - Documentada la generación local con `export CHAT_ENCRYPTION_KEY="$(openssl rand -hex 32)"` o archivo `.env`, así como la necesidad crítica de conservarla para perfiles persistidos con cuentas OAuth en reposo.
3. **Smoke testing y contenedor de release**:
   - `scripts/smoke_image.py`: configurado con variable de entorno `CHAT_ENCRYPTION_KEY` válida (32+ bytes) para verificar que la release compilada de producción arranca y pasa todas las comprobaciones con su propia clave inyectada.
4. **Regresiones y Verificación**:
   - `test/web_f2_test.exs`:
     - Pruebas de desconexión activa concurrente ante regeneración de capability token y eliminación de perfil, con acumulación de buffer de tramas SSE (`\n\n`), comprobando emisión de evento de error, cierre de socket y rechazo 401 en subsecuentes accesos.
     - Prueba de HTTP/1.1 keep-alive: verificación de que `Registry.lookup/2` queda vacío tras concluir la respuesta, que la conexión reutilizada para otro perfil opera con aislamiento total sin ser interrumpida por revocaciones del perfil anterior, y que las salidas 401 desregistran de inmediato.
   - `test/oauth_test.exs`: pruebas exhaustivas de validación de clave de cifrado para entornos test, dev, prod y release, comprobando tipos no binarios, longitud insuficiente, clave por defecto y clave válida.
   - Suite completa ExUnit: **163/163 pruebas PASS** en doble pasada (semilla 0 y 424242, 0 fallos, 0 skips, 0 exclusiones).
   - Verificaciones de formato, static checks (`python3 scripts/security_static.py`), escaneo de secretos (`python3 scripts/scan_secrets.py`), trazabilidad (`python3 scripts/check_traceability.py`) y smoke test de release (`python3 scripts/smoke_image.py`) con resultado 100% PASS.

## Autenticación de sesión en Panel de Creador y autorización por perfil — issue #30

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/30
- Rama: `feat/30-dashboard-session-auth`
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/30-dashboard-session-auth`

### Alcance e Implementación:
1. **Gestión de Sesiones Seguras (`ChatOverlay.Session`) (SEC-12, SEC-14, ADR-0003)**:
   - Emisión de cookies de sesión `chat_overlay_session` con cifrado simétrico autenticado AEAD (AES-256-GCM) utilizando `ChatOverlay.Crypto.encrypt_aead/3` y `decrypt_aead/3` con la clave de cifrado del sistema (`ChatOverlay.OAuth.encryption_key/0`).
   - Separación estricta de dominios criptográficos (AAD): el AAD se fija a `"chat_overlay_session"` evitando confusiones o sustituciones de tokens (ej. parámetros state de OAuth con AAD `"oauth_state"`).
   - Atributos de seguridad de cookie: `HttpOnly: true`, `SameSite=Lax`, `Path: "/"`, `Max-Age: 604_800` (7 días) y `Secure` condicionado a conexiones HTTPS o cabecera de proxy reverso (`x-forwarded-proto: https`).
   - Verificación de timestamps: comprobación de expiración (`expires_at`) e integridad en cada petición.
   - Endpoint de estado de sesión: `GET /api/auth/me` (y alias `GET /api/session`) que devuelve el estado de autenticación y metadatos de sesión (handle, proveedor, user_id, timestamps).
   - Endpoint de cierre de sesión: `POST /api/auth/logout` protegido contra CSRF (verificación de origen) que purga la cookie con `max-age=0`.
2. **Emisión de Sesión en Callback OAuth (`ChatOverlay.Web.oauth_callback/2`)**:
   - Al completar exitosamente el intercambio OAuth 2.0 PKCE con Twitch/Google e indexar la vinculación de cuenta, se genera la cookie de sesión del creador en `conn` antes de redirigir al panel (`/?handle=...&linked=...`).
3. **Control de Acceso Estricto por Perfil y Aislamiento (SEC-12, SEC-14)**:
   - `GET /api/profiles`: alcance acotado (`Session.scope_profiles/2`). Un creador autenticado únicamente recibe su propio perfil en la respuesta JSON, garantizando aislamiento total entre creadores. En accesos remotos no autenticados, responde 401 Unauthorized.
   - Endpoints protegidos en `ChatOverlay.Web`:
     - `POST /api/profiles/:handle/token/regenerate`
     - `POST /api/profiles/:handle/media`
     - `POST /api/profiles/:handle/unlink/:provider`
     - `POST /api/profiles/:handle/sync-youtube`
     - `POST /api/media/presign`
     - `DELETE /api/profiles/:handle`
     - `POST /api/profiles` (creación de perfiles)
   - Respuestas estándar: 401 Unauthorized si falta sesión o credenciales en contexto no-demo, 403 Forbidden si un creador autenticado intenta mutar o acceder a un perfil ajeno (tampering / suplantación cross-profile).
4. **Modo Demo y Loopback de Fricción Cero**:
   - Acceso no autenticado permitido exclusivamente para conexiones locales loopback (`127.0.0.1` o `::1`) bajo perfiles con fuentes demo (`mode: "demo"`) o `config/demo.json`, garantizando compatibilidad total con el quick start y las pruebas automáticas.
5. **Panel de Creador y Frontend (`priv/static/index.html`, `app.js`, `app.css`)**:
   - Añadido banner visual de sesión en el panel que informa del handle y proveedor activo si existe sesión, junto con el botón «Cerrar sesión» con llamada a `/api/auth/logout`.
   - Soporte para adjuntar token de capacidad en el inicio de vinculación remota.
   - Mapeo de errores explícitos para rechazo de titularidad no autorizada (`unauthorized_profile_claim`).
   - Modificación 100% segura usando `.textContent` y manipulación DOM sin violar directivas de sink HTML en `security_static.py`.
6. **Resolución de Bloqueantes de Revisión (PR #31)**:
   - **Bloqueante 1 (Sesión tras desvinculación)**: `Session.authorize/3` valida que la cuenta vinculada exista en el perfil y que coincidan `user_id` y `account_version`. La ausencia del vínculo invalida la sesión devolviendo `{:error, :unauthorized}`. `POST /api/profiles/:handle/unlink/:provider` revoca el token en ETS y expira la cookie.
   - **Bloqueante 2 (Primer inicio remoto)**: `api_oauth_authorize/2` permite iniciar el flujo OAuth a creadores remotos acreditando su `capability_token` (vía `?token=` o cabecera `Authorization: Bearer <token>`) o vinculación previa. El método de prueba (`auth_proof`) se cifra en el parámetro AEAD `state`.
   - **Bloqueante 3 (Comprobación de titularidad en callback)**: `oauth_callback/2` comprueba la titularidad cuando no existen identificadores previos en el perfil, exigiendo `auth_proof in ["session", "capability_token"]` (o modo demo). Intentos no autorizados se rechazan con `error=unauthorized_profile_claim`.
   - **Estabilidad de Carga Sintética**: `scripts/load.exs` incorpora drenaje activo con timeout de seguridad (10s) para asegurar la recolección del 100% de muestras en runners de CI compartidos antes de parar lectores.
7. **Regresiones y Verificación**:
   - `test/session_test.exs`: 16 pruebas unitarias verificando ciclo de vida, expiración, anti-tampering, flags de cookie (`HttpOnly`, `SameSite=Lax`, `Secure`), separación de AAD, invalidación tras desvincular y scoping.
   - `test/web_session_auth_test.exs`: 19 pruebas de integración HTTP sobre Bandit verificando `GET /api/auth/me`, `POST /api/auth/logout`, aislamiento en `GET /api/profiles`, rechazo 401/403, emisión de cookie en OAuth callback, inicio con token de capacidad y rechazo de reclamación no autorizada.
   - Suite completa ExUnit: **198/198 pruebas PASS** en doble pasada (semilla 0 serial y semilla 424242 concurrente, 0 fallos, 0 skips, 0 exclusiones).
   - Verificaciones automáticas completas: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `python3 scripts/security_static.py`, `python3 scripts/scan_secrets.py`, `python3 scripts/check_traceability.py`, `docker build --target validation`, `docker run` con `--network none`, test de carga sintética `scripts/load.exs 30` (30.000/30.000 muestras entregadas, p95 49-50 ms, 0 errores) y release smoke test `python3 scripts/smoke_image.py`.
   - GitHub Actions CI (PR #31, Run `36852264248`): **100% PASS** (`source-and-tests` ✓, `image-security` ✓, `quality-gate` ✓).


## Seguimiento y cumplimiento estricto de cuotas de almacenamiento R2 — issue #32

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/32
- Rama: `feat/32-media-storage-quotas`
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/32-media-storage-quotas`

### Alcance e Implementación:
1. **Cómputo Atómico y Seguimiento de Cuota (`ChatOverlay.Profiles`) (SEC-05, SEC-17, ADR-0003)**:
   - `Profiles.update_media/3`: calcula atómicamente la suma exacta de almacenamiento ocupado por los archivos R2 activos (`source: "r2"`) del perfil y actualiza de forma persistente `storage_used_bytes`.
   - Cumplimiento estricto fail-closed: si la suma total de almacenamiento excede `storage_quota_bytes` (10 MB por defecto), la operación se rechaza atómicamente con `{:error, :quota_exceeded}` sin modificar la configuración ni el uso persistido.
   - Liberación y deducción de cuota: al reemplazar un archivo por otro, al cambiar el origen de R2 a URL externa (`source: "external"`, 0 bytes de cuota consumida) o al eliminar una alerta (`url: ""`), el espacio correspondiente se deduce de inmediato.
   - Trazabilidad y saneamiento de objetos huérfanos: `Profiles.update_media/3` (con `with_removed_keys: true`) y `Profiles.delete/2` detectan los identificadores de claves R2 huérfanas o reemplazadas (`removed_r2_keys`) para su posterior eliminación.
2. **Generación de URLs Prefirmadas SigV4 DELETE para R2 (`ChatOverlay.Media`)**:
   - `Media.generate_presigned_delete/1`: generación de peticiones y URLs prefirmadas DELETE compatibles con AWS SigV4 y Cloudflare R2 utilizando exclusivamente primitivas nativas de Erlang/OTP `:crypto` (`:crypto.mac(:hmac, :sha256, ...)`).
   - `Media.r2_config/0`: centralización de configuración de S3/R2 a partir de variables de entorno y configuración de aplicación.
   - `Media.presigned_delete_url/2`: helper de conveniencia para generar URLs de eliminación de claves específicas.
   - Zero Server Footprint: las URLs DELETE son emitidas por el backend y ejecutadas de forma asíncrona por el navegador del cliente (`fetch(url, { method: "DELETE" })`), manteniendo cero consumo de red de salida y cero dependencias de SDKs pesados en el backend.
3. **Anti-Tampering y Validación Criptográfica de Subidas (`ChatOverlay.Media`, `ChatOverlay.Web`)**:
   - `Media.generate_upload_token/4` y `Media.verify_upload_token/3`: token criptográfico AEAD (AES-256-GCM, AAD `"media_upload_token"`) que vincula unívocamente handle, key, size y category.
   - En `POST /api/media/presign`: emite el `upload_token` autenticado y tiene en cuenta el reemplazo de alertas de la misma categoría (`effective_used = max(0, used - existing_size)`) para no bloquear reemplazos válidos cerca del límite de cuota.
   - En `POST /api/profiles/:handle/media`: valida el `upload_token` o verifica que el tamaño declarado sea entero positivo no superior al máximo de categoría (`max_bytes(category)`). Cualquier intento de manipulación se rechaza con 422 Unprocessable Entity.
   - En `DELETE /api/profiles/:handle` y `POST /api/profiles/:handle/media`: devuelve las `cleanup_urls` correspondientes a objetos R2 sustituidos o desasociados.
4. **Visualización en Panel de Creador (`priv/static/index.html`, `app.js`, `app.css`)**:
   - Widget interactivo `#storage-quota-card` en la sección de alertas multimedia del panel del creador: barra de progreso visual con cambios dinámicos de color (verde normal, amarillo >70%, rojo >90%) y texto detallado (`X KB / Y MB usados (Z%)`).
   - Envío de metadatos `key`, `size` y `upload_token` en la asociación de alertas.
   - Ejecución desatendida en segundo plano de las `cleanup_urls` devueltas tanto al guardar alertas como al eliminar un perfil.
   - Modificación 100% segura mediante `.textContent`, `.style.width` y APIs de DOM nativas, superando sin observaciones `scripts/security_static.py`.
5. **Regresiones y Verificación**:
   - `test/media_test.exs`: pruebas unitarias de firmas SigV4 DELETE, `presigned_delete_url/2`, emisión de tokens de subida y rechazo de tokens manipulados/forjados.
   - `test/profiles_f2_test.exs`: pruebas de cálculo atómico de `storage_used_bytes`, rechazo por exceso de cuota, liberación de cuota ante reemplazo/eliminación/switch externo y retorno de claves R2 en eliminación de perfil.
   - `test/web_f2_test.exs`: pruebas de integración HTTP verificando emisión de `upload_token` en presign, cálculo y actualización de cuota en `POST /api/profiles/:handle/media`, generación de `cleanup_urls` para R2, rechazo 422 de token manipulado y cuota excedida, y retorno de `cleanup_urls` en `DELETE /api/profiles/:handle`.
   - Suite completa ExUnit: **208/208 pruebas PASS** en 9.3s (0 fallos, 0 advertencias de compilación).
   - Verificaciones automáticas 100% PASS: `python3 scripts/security_static.py`, `python3 scripts/scan_secrets.py`, `python3 scripts/check_traceability.py`, `mix format --check-formatted`.
## Deuda F2 — persistencia (#51)

- Rama/worktree: `fix/51-profile-persistence`, `../chat-overlay-worktrees/51-profile-persistence`; PR: #56.
- Reproducción previa: 8 de 11 regresiones de persistencia fallan en la base 8c11e2d.
- Corrección: escritura obligatoria antes de mutar runtime; eliminación confirma
  persistencia antes de revocar; archivo privado 0600 y reemplazo atómico dentro
  de staging 0700, sincronizado y acotado a 64 KiB. Errores HTTP de almacenamiento
  no incluyen rutas internas. El bloqueo OAuth en memoria tras fallo se preserva
  como excepción explícita y devuelve error de escritura.
- Verificación local: `mix check`, 211 pruebas PASS sin warnings; tests de disco,
  concurrencia, permisos, recarga, límite de documento y symlink incluidos.
- ADR 0004 describe controles y límites. SEC-13 no se declara satisfecho por usar
  JSON: decisión sobre aislamiento equivalente o PostgreSQL/RLS pendiente de
  Kalista; #51 permanece abierto hasta resolverla.
- #32: el operador autoriza hacerse cargo de sus cambios no confirmados el
  02-10-2026. Copia previa en `/tmp/chat-overlay-32-takeover.patch` antes de editar.
- Próximo: integrar esta base con #32 y continuar recuperación de claves (#40),
  ciclo de vida/validación multimedia (#48/#49), controles/documentación (#41/#42)
  y pruebas web/OBS (#43). No se ha aprobado merge ni despliegue.

## 2026-10-02 — #32, continuación autorizada del worktree

- Rama `feat/32-media-storage-quotas`, worktree `../chat-overlay-worktrees/32-media-storage-quotas`.
- Se conservaron los cambios heredados en `0e0e1ca` y se integró localmente #51
  (`470348d`); PR base de persistencia: #56. La PR de cuotas debe apilarse sobre ella.
- Reservas persistentes y serializadas, claves por perfil, tickets temporales,
  firma de longitud/MIME, verificación HEAD con fixtures, cuota pendiente y limpieza
  supervisada con reintentos. DELETE ya no depende del navegador.
- Ver `docs/media-storage.md`: SEC-17/#49 no está cumplido, no hay prueba R2 real;
  #48 mantiene conciliación heredada, reautenticación y visibilidad de borrados pendientes.
- El documento incorpora `media_objects`; conservar backup e inventario para rollback.
  No desplegar ni hacer merge sin autorización humana.

## 2026-10-02 — recuperación offline (#40)

- Rama/worktree `feat/40-key-recovery` / `../chat-overlay-worktrees/40-key-recovery`,
  apilado sobre #32 para conservar también `media_objects` en recuperación.
- `ChatOverlay.Recovery` y `scripts/recovery.exs`: copia completamente cifrada,
  restauración a un archivo nuevo y rotación completa de credenciales con AAD por perfil.
  Sin arranque de servicios en CLI, sin mutación de claves o entorno y sin overwrite.
- `docs/recovery.md` describe custodia, identificador de clave, corte coordinado,
  efectos en cookies/OAuth/tickets, capabilities OBS y rollback sin resucitar datos.
- Pruebas solo sintéticas. No existe autorización para rotar claves reales,
  detener/desplegar producción ni hacer merge.

## 2026-10-02 — reconciliación documental (#41)

- Rama `docs/41-f2-evidence`, worktree `../chat-overlay-worktrees/41-f2-evidence`.
- README, contrato, AGENTS, arquitectura, amenazas, operación, plataformas,
  cumplimiento y verificación distinguen cierre histórico #21 y candidatas nuevas.
- ADR 0005 propone PostgreSQL/RLS/Postgrex y cuarentena con FFmpeg aislado.
  Aprobación solicitada al operador en esta sesión; no interpretar silencio como aprobación.
- Esta documentación no debilita requisitos ni declara F3/F4, merge o producción autorizados.

- El pre-push de #41 detectó una carrera en la prueba de baja de Registry (#42):
  `Profiles.delete` espera terminar hijos, pero Registry procesa sus notificaciones
  DOWN de forma asíncrona. La prueba ahora monitoriza muerte de ambos PIDs y exige
  retirar ambas entradas con un límite de 1 s; no se salta ninguna aserción.

## 2026-10-02 — selección ASVS (#42)

- Rama/worktree `docs/42-asvs-evidence` / `../chat-overlay-worktrees/42-asvs-evidence`.
- `docs/asvs-f2.md`: 43 IDs de ASVS 5.0.0 verificados contra fuente oficial fijada,
  nivel, evidencia local, estado y deuda; no se presume PASS de filas no evaluadas.
- #42 sigue abierto: política de sesiones, mix-up, cookies/cliente, matriz exhaustiva
  de rutas y revisión humana. #43 hará evidencia navegador/OBS por separado.

## 2026-10-02 — navegador y OBS (#43)

- Worktree/rama `../chat-overlay-worktrees/43-browser-evidence` / `test/43-browser-evidence`.
- Fixture local y checks de navegador sintéticos: login/A-B/HttpOnly/permisos,
  error multimedia, capabilities/SSE y logout pasan a 1280x800 y 390x844.
- Corregidos controles de subida para can_upload=false y limpieza de copias de
  capabilities al cerrar sesión; logout fallido ya no simula éxito.
- OBS real 32.2.2 FAIL por inicialización CEF código 28; captura vacía. Ver
  `docs/browser-f2.md`. No se atribuyen pruebas visuales al snapshot T3 fallido.
- Kalista aprobó explícitamente ambas unidades de ADR 0005 en esta sesión:
  PostgreSQL/RLS/Postgrex y cuarentena FFmpeg, para implementación/pruebas locales.
  Agentes trabajan en ramas aisladas; no merge/despliegue ni datos reales.

- Runner CI de #43 preparado con Playwright 1.63.0 (dev-only, Apache-2.0, Node >=20),
  lockfile y checks compartidos exportados como función. Contenedor sintético con red
  interna, publicación loopback y recursos acotados; navegador restringido al fixture.
- Validación local del runner limitada a sintaxis/lockfile/metadatos. No se ejecutó
  Playwright local ni se sustituyó la evidencia T3. Primera ejecución real pendiente
  de CI tras PR; no cerrar #43 ni presentar Chromium como validación OBS.
## Evidencia para carga sostenida — issue #4 (2026-10-02)

- PR: https://github.com/tears-mysthrala/chat-overlay/pull/33 (lista para revisión; CI/revisión humana pendientes al redactar).
- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/4 (entrega parcial, Refs #4).
- Rama: `test/4-soak-evidence`.
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/4-soak-evidence`.
- Base: `8c11e2d`, con las correcciones de autorización de #30/#31 ya integradas.
- Necesidad: dos medidas de memoria (inicio/fin) no permiten revisar tendencia durante
  las pruebas de 4/24 horas. Instrumentar la prueba existente sin cambiar producción.
- Cambios: muestras de memoria BEAM/procesos cada minuto y al finalizar; tiempos UTC
  y duración real; etiqueta de revisión; histograma limitado a 1.001 buckets,
  redondeo conservador y rechazo explícito de mediciones vacías. Cinco regresiones
  cubren percentil, límites, redondeo y muestreo. Comandos en `scripts/README.md`.
- Verificado: `docker build --target validation -t chat-overlay:4-soak-validation .`
  (formato y compilación sin advertencias); `scripts/ci_tests.sh` en contenedor sin red,
  2 CPU, 1 GiB, 128 PIDs y dos schedulers: **203/203 PASS** con semillas 0 y 424242.
  `python3 scripts/check_test_report.py output/tests/exunit-0.json output/tests/exunit-424242.json`
  confirma cero fallos, skips y exclusiones. Cinco tests Python del validador PASS.
- Carga de 65 segundos, sin red y con los mismos límites: **4.750 eventos,
  47.500/47.500 muestras, cero errores, p95 50 ms**, duración real 65.043 ms.
  Host x86_64, AMD Ryzen 3 7320U (8 CPUs lógicas); contenedor limitado a 2 CPU.
  Muestras a 0/60.001/65.043 ms: memoria BEAM 455.999.776/484.691.128/82.122.664 bytes,
  procesos 530/530/330. La última muestra es tras parar lectores; este descenso
  no demuestra estabilidad sostenida. Informes locales en `output/tests/` y
  `output/load-65.json` (no versionados). Imagen validada:
  `sha256:d2d8d4f44d972f65d4ddf4b00fbbec13dbd85e206fedc6257642c7b38b66f068`.
- Trazabilidad, secretos, estática, tests Python y `git diff --check`: PASS.
  Hook pre-push completo PASS (incluye una tercera pasada de 203 tests); sin excepción.
  Primer intento bloqueado por selección accidental de Elixir 1.20.2 en PATH;
  corregido el entorno del comando a 1.20.4 sin cambiar configuración global.
- Límites: no se han ejecutado 4/24 horas, recuperación de workers ni nueva prueba
  en OBS/upstream; no hay nueva auditoría del artefacto de release, cuyo código
  permanece igual. No se evalúan aquí cumplimiento legal ni condiciones upstream.
- Trabajo ajeno preservado: worktree sucio `32-media-storage-quotas`, issue #32,
  sigue en curso; no se han editado sus archivos ni compartido sus builds.
- Siguiente paso: revisión humana y CI de esta PR; ejecutar las pruebas sostenidas
  sobre revisión/imagen identificadas y analizar la tendencia bajo #4. No hacer
  merge ni publicar sin autorización expresa del operador.

## Continuación local OAuth — 07-10-2026, Refs #42

Rama `security/42-oauth-session`, worktree `D:/github/_worktrees/chat-overlay-f2-security`.
Transacciones por navegador, consumo único, origen HTTPS configurado, cuotas por
solicitante y revalidación serializada de permisos/identidad. Revocaciones acotadas
con invalidación de sesiones tras reiniciar. Base64 AEAD canónico.

Última imagen `sha256:523f4bf8e38cbc4b80f9461f1f10b34721159dad4ee10ba976fe2f63221586c5`:
264/264 PASS en ambas semillas, reportes completos. Revisión Sol medium ronda 7
limpia, estática. Ver `docs/oauth-runtime.md` y
`docs/workflows/f2-security/runs/2026-10-07.md`.

No cierra #42 ni F2: navegador/proxy/proveedores reales, CI y revisión humana
pendientes. ADR0005 A/B permanece en ramas separadas; no integrar la cuarentena
con siete regresiones actuales. Sin push, PR nueva, merge ni despliegue.
## Unidad A PostgreSQL RLS — 05-10-2026, Refs #51

Rama security/51-postgres-rls, worktree D:/github/_worktrees/chat-overlay-postgres,
base 1bc715c875ebe61a63b533705b88ae9c066cf3c7. Autorización expresa A/B ADR0005
para implementación y validación local. Esta rama solo implementa A. No push,
PR externa, merge, despliegue ni cuentas reales. Issue #51 permanece abierta.

Backend integrado en producto, roles owner/runtime/bootstrap separados,
RLS/FORCE en perfiles/cuentas/objetos, contexto transacción derivado de servidor,
import/export offline validados, selección explícita y sin fallback DB -> JSON.
Ver [almacenamiento](postgres-storage.md) y [registro de pruebas/revisión](workflows/postgres-rls/runs/2026-10-05.md).
ARCH-06/#39 sigue pendiente: pools/caché dentro de una BEAM, singleton soportado.

Actualización 07-10: imagen local reconstruida `55d27537510d`, 25 pruebas PostgreSQL
por semilla y boot/mutación/restart PASS. Exportación exclusiva con regresiones
concurrente/symlink incorporada. Revisión estructurada Sol bloqueada por aprobación
automática de red; inspección manual completada, revisión independiente pendiente.
La integración con OAuth `d261ebf` se valida en otra candidata; esta unidad no
acredita cierre de F2, CI remota o publicación.
## Unidad B local — 07-10-2026, Refs #49

security/49-media-quarantine, D:/github/_worktrees/chat-overlay-quarantine.
Ciclo privado pending/processing, normalización aislada, promoción por hash,
activación autenticada y ledger conectado. Diez pruebas decoder y ocho coordinator
PASS, storage sintético; BEAM255 dual PASS más ledger16 PASS con nueva regresión.
Decoder89432cb33a13: FFmpeg mínimo fijado, backports CPython comprobados, licencias
incluidas. Scanner seis matches sin VEX decoder aprobado; no declarar gate verde.
La reserva pública incierta se conserva hasta sellado, también tras retry/restart.
Journal128 acumulado requiere mantenimiento; autorización final puede impedir
activación dejando artefacto normalizado público pendiente de retirada, con cargo.
Revisión Sol scoped y fix comprobado por inspección. No R2 real/OBS/CI remota,
PR, push, merge ni despliegue. Integración candidata se valida por separado.
Ver docs/workflows/media-quarantine/runs/2026-10-07.md.

## Candidata F2 integrada y revisión oficial — 07-10-2026, Refs #55

`security/55-f2-local-candidate`, D:/github/_worktrees/chat-overlay-f2-candidate.
OAuth/A/B integrados localmente: 274 generales y 26 PostgreSQL por semilla PASS;
10 decoder y 8 coordinator PASS; escritorio sintético login/permisos/OBS capability/
SSE/logout PASS. Los siete fallos antiguos de B quedaron resueltos.
OpenAI Codex Security security-diff-scan completado y sellado sobre `aab4572`:
44 entradas fuente oficiales revisadas, cero nuevos hallazgos reportables,
cobertura parcial con seguimientos. Solo Sol. La autorización de revisión ya
superó el bloqueo histórico de envío; no se usó la skill personal autoreview.
Seis matches decoder sin suppressions y cobertura FFmpeg git siguen pendientes;
demo detrás de proxy loopback requiere evaluación de configuración. No cierre F2,
publicación o despliegue. Registro actual: docs/workflows/f2-security/runs/2026-10-07-candidate.md.

## Seguimientos y VEX aprobado — 07-10-2026, Refs #55

Demo/proxy corregido en 43568fa: proxy loopback configurado y peer ausente no
conceden excepción anónima. 278 generales y 26 PostgreSQL por semilla PASS;
revisión nueva Sol sin bypass/regresión concreta. Ver seguimiento F2.
Kalista aprobó explícitamente la propuesta VEX del decoder: tres fixed Python
por backport y un not_affected Busybox limitado al launcher/imagen documentados.
Busybox wget sigue presente; no se declara parcheado. Activación condicionada a
digest/arquitectura/hashes de fuentes y runtime/aprobación/caducidad 2026-10-21.
Informe bruto conservado; cobertura completa FFmpeg git y validación real/CI
remota siguen pendientes. No merge, push ni despliegue.
Auditoría decoder con VEX exit 0: seis coincidencias brutas conservadas,
seis cubiertas por las declaraciones aprobadas y cero activas; igualdad CVE/PURL
verificada. Registro: docs/workflows/f2-security/runs/2026-10-07-vex-approved.md.

## Despliegue Benten autorizado — 07-10-2026, Refs #55

VM9502 dedicada,192.168.1.114. Backend PostgreSQL TLS privado operativo;
release a5c3da6a7cfc con OpenSSL3.5.9, smoke/escaneo PASS. Persistencia real y
autostart tras reboot comprobados, perfil sintético eliminado, firewall guest.
Publicación mysthrala.com bloqueada por cf401 y rechazo automático de búsqueda
de perfiles/rutas de autenticación alternativas. No DNS/ingress aplicado ni
HTTPS externo probado. OAuth/R2 sin credenciales, decoder cargado sin coordinador.
Checkpoint local quiesced; no restore/offsite validado. Registro y siguientes
pasos: docs/workflows/deployment/runs/2026-10-07.md. No declarar despliegue público
terminado ni F2 cerrado.

## Publicación HTTPS completada — 07-10-2026, Refs #55

https://overlay.mysthrala.com llega a VM9502 mediante connector personal9501.
Autorización específica resuelve rechazo inicial: perfil cf personal-bankmcp.
Túnel versión2, banking y fallback preservados; CNAME overlay creado. Firewall
permite solo UID del connector hacia guest4100; workstation LAN bloqueado.
HTTPS root/readiness/assets PASS, API anónima401; banking /mcp mantiene401 y
connector activo sin reinicio. OAuth/R2/propietario inicial, SSE/OBS y reserva
DHCP pendientes; mensaje anónimo UI401 genérico y script inline bloqueado por
CSP registrados como deuda. No F2 cerrado ni pruebas reales de plataformas.
Ver docs/workflows/deployment/runs/2026-10-07-public.md.

## Lectura Twitch real y unidad local — 07-10-2026, Refs #47, #62

Readers9250d51 desplegados en VM9502 con imagena9c03ede9afe y migración del
perfil propietario. Consentimiento Twitch con lectura de chat completado;
mensaje autorizado de prueba recibido una vez en lector, fuente Disponible.
Chats YouTube público/oculto y OBS confirmados, eventos después eliminados con
confirmación explícita; multimedia OBS y revocación actual pendientes. Registro #47 actualizado en el worktree
chat-overlay-oauth-readers, todavía sin commit documental.

Worktreechat-overlay-local-media, ramafeat/62-local-media, commit860deeb:
almacenamiento Linux privado, adaptador coordinador, relay HTTP con autorización,
salida normalizada con hash e inventario y frontend. Ocho tests Linux/API privada
y cuatro tests web nuevos PASS; suite290 PASS, decoder real emotes112/WAV2s PASS,
E2E Linux completo PASS, PostgreSQL26 PASS en dos seeds. Revisión oficial
4a10c926 completada sin vulnerabilidades reportables. Imagen a42d61be desplegada
en Benten con coordinador privado4199 y permiso de subida tearsmysthrala;
SBOM295 válido/escaneo0 activos4 VEX. Quedan panel upload/OBS/revocación y deuda
operativa (registros acotados, backup externo/restore, ARCH06, CI). Chrome requiere
acceso a file URLs de la extensión o selección manual de fixture. Continuar desde
docs/workflows/deployment/runs/2026-10-07-local-media.md; preservar otros worktrees.

## Recuperación externa y mantenimiento local — 07-10-2026, Refs #40/#62/#39

PR65 integrada en mainfb016d8: multimedia/preview reales OBS, revocación y
recuperación verificadas; CI diez checks PASS. CodeRabbit/Copilot omitidos por
límites, no aprobaciones. Dos P1 Codex de deploy corregidos antes del merge.
Nueva unidad chore/40-backup-maintenance en worktree chat-overlay-ops-40:
backup real coherente cifrado CMS AES-256-GCM a Drive existente aprobado por el
operador; presencia remota y tamaño confirmados, compartición desactivada.
Restore aislado sin red: 1perfil/2cuentas/2objetos, FORCE RLS y hashesmedia PASS,
descifrado de cuentas en runtime real PASS. Descarga independiente materializada
por el conector HTTP403; restore usa copia local verificada de Drive.
Clave RSA fuera de Drive con ACL privada, sin nueva dependencia de producción.
Compactación offline conservadora preparada y 3regresiones Linux PASS; aún no
aplicada en producción. Revisión/CI/merge de esta unidad pendientes. No backup
periódico ni segunda custodia de clave configurados. Propuesta ARCH06 ADR0008
preparada; protocolo interno y cambio de arquitectura requieren decisión explícita.
Ver docs/workflows/deployment/runs/2026-10-07-ops-recovery.md.
