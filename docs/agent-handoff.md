# Handoff F2 — issue #17 (Panel de Creador, Capability Tokens, Módulo Multimedia R2 y URLs Externas)

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

