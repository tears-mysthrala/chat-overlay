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
   - Pull Request: https://github.com/tears-mysthrala/chat-overlay/pull/20
   - Rama: `test/19-obs-f2-validation`
   - Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/19-obs-f2-validation`
   - Script automatizado vía OBS WebSocket (puerto 4455): `scripts/test_obs_f2.py`.
   - Pruebas superadas en vivo en OBS Studio 32.2.2 (CEF 152.0.7977.83 / Wayland):
     1. **Rechazo 401 Unauthorized sin token**: Verificado en OBS Browser Source. El overlay devuelve 401 con pantalla de aviso amigable y CSP intacta (`obs_f2_401_unauthorized.png`).
     2. **Acceso autorizado 200 OK con Capability Token**: OBS conecta al stream SSE y renderiza el chat en directo de Twitch con badges, timestamps y sanitización XSS (`obs_f2_authorized_live.png`).
     3. **Revocación inmediata en caliente**: Al regenerar el token mediante el endpoint API `/api/profiles/:handle/token/regenerate`, el token anterior queda invalidado de inmediato en el backend y la fuente en OBS pasa a 401 (`obs_f2_revoked_401.png`).
     4. **Restauración con nuevo token**: Al actualizar la fuente en OBS con el nuevo token generado, el overlay reanuda la conexión SSE sin reiniciar el proceso ni perder el estado del canal (`obs_f2_restored_live.png`).
     5. **Lienzo completo y transparencia**: Verificado sobre escena con fondo sólido (`TestColor`); la transparencia del overlay es total y el texto se dibuja sin halos ni recortes (`obs_f2_scene_full.png`).
     6. **Panel de Creador (Chromium headless)**: Captura completa del panel con gestión de enlace OBS, advertencia de regeneración y pestañas de alertas multimedia R2 (`dashboard_f2_full.png`).
   - **Ajustes de CSP aplicados**:
     - Sustituido estilo inline en la página de error 401 por hoja de estilo `app.css` y clase `.unauthorized-body` (evitando violación de `style-src`).
     - Añadido el hash `sha256-Yd1GhiWi47kUsi/SDfKQTY7E39TboDOQOjTJBsT0GQg=` a `style-src` en `ChatOverlay.HTTP` para autorizar de forma estricta el CSS inyectado por defecto por OBS Studio sin relajar la directiva a `unsafe-inline`.


