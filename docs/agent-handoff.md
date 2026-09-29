# Handoff F1 — issue #13 (Autodetección de canales públicos y unificación multistream)

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/13
- Rama: `feat/13-twitch-youtube-discovery`
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/13-twitch-youtube-discovery`
- PR previa: https://github.com/tears-mysthrala/chat-overlay/pull/12 (MERGED en main `ae6ffb2`).
- Autorizado: Ampliación de resolución y agregación multistream F1 (resolución de canales de YouTube enlazados públicamente en Twitch para unificar feeds de chat en caliente, sin cuentas de usuario ni perfiles privados de F2). Aprobado y solicitado por el operador en issue #13.

Evidencias operativas y técnicas en esta entrega:
- **Autodetección de YouTube desde Twitch (`ChatOverlay.Resolver`)**:
  - Detección automatizada mediante consulta a la API pública GraphQL de Twitch (`https://gql.twitch.tv/gql`, social links del broadcaster) con fallback de parsing sobre la biografía/descripción (`description`) del usuario de Twitch obtenida en Helix.
  - Validación de red en `ChatOverlay.Net`: adición de `gql.twitch.tv` a la lista de hosts permitidos (`@hosts`) con control estricto de IP pública y límites de respuesta (256 KiB).
  - Comprobado en vivo contra perfiles reales:
    - `gilraennr` -> resuelto enlace de YouTube `https://www.youtube.com/channel/UCFUOHZSB9UdNRkjSBx3fpOQ`.
    - `revenant` -> resuelto enlace de YouTube `https://www.youtube.com/@REVENANT_Gameplays`.
- **Integración y supervisión en perfiles unificados (`ChatOverlay.Profiles`, `ChatOverlay.Config`, `ChatOverlay.Store`)**:
  - Esquema ampliado de perfiles con campo opcional y validado `"linked_youtube"` (`<= 2048` caracteres).
  - Al añadir un canal de Twitch (`resolve_target_with_meta/2`): si el canal de YouTube detectado está emitiendo en directo, se fusiona automáticamente la fuente de YouTube generando una feed multistream unificada de inmediato. Los enlaces transitorios a vídeos (`watch?v=`, `youtu.be`) se normalizan automáticamente a la URL canónica y estable del canal (`/channel/UC...`).
  - Si no está en directo, se guarda la referencia en `linked_youtube` sin bloquear ni dar error.
  - Sincronización atómica en caliente (`sync_youtube/2`): busca emisiones activas del canal de YouTube asociado e incorpora la fuente en caliente mediante serialización en el GenServer `Profiles`, evitando condiciones de carrera concurrentes y preservando `linked_youtube` en cualquier mutación de perfil.
  - **Continuidad del Store y entrega en caliente**: se incorpora `Store.update_sources/2` para actualizar las fuentes permitidas dinámicamente sin reiniciar el proceso del Store ni perder el historial de chat acumulado ni las barreras de deduplicación.
  - **Suscripción SSE dinámica (`ChatOverlay.Stream`)**: resolución en caliente de plataformas activas en el stream SSE, permitiendo que los visores ya conectados reciban de inmediato los eventos de la nueva plataforma sin necesidad de reconectar.
- **Endpoints de API REST (`ChatOverlay.Web`)**:
  - `POST /api/profiles/:handle/sync-youtube`: permite al frontend solicitar la sincronización en vivo del canal de YouTube asociado. Protegido con validación de cabecera Origin y Content-Type JSON.
  - `POST /api/resolve`: enriquecido para devolver metadatos con el estado de YouTube (`discovered_youtube_url`, `youtube_live`, `youtube_error`).
- **Panel de control UI (`priv/static/app.js`, `priv/static/app.css`)**:
  - Indicador visual (badge) para canales de Twitch que tienen un canal de YouTube vinculado.
  - Botón accesible para sincronizar o resincronizar transmisiones futuras cuando concluya una emisión anterior.
  - Notificaciones en español sobre el estado de la vinculación y sincronización.
- **Suite de pruebas**:
  - 77 tests PASS (5 nuevos tests cubriendo detección de enlaces /c/, /user/, watch?v=, preservación de `linked_youtube`, continuidad del Store, endpoint de sincronización y mitigación CSRF/Origin).
  - 0 advertencias de compilación (`mix compile --warnings-as-errors`).
  - Formato verificado con `mix format --check-formatted`.
- **Seguridad de dependencias (SUP-07 / DEV-12)**:
  - Actualización de `mint` a `1.11.0` y `hpax` a `1.1.0` para subsanar los avisos de seguridad de Hex (`EEF-CVE-2026-91043`, `EEF-CVE-2026-92103`, `EEF-CVE-2026-94194`).
  - `mix hex.audit` verificado 100% limpio (0 avisos de seguridad).


- **Evaluación de interfaces no documentadas (ARCH-07)**:
  - Registro de viabilidad, términos, límites acotados (256 KiB), tratamiento de datos (variables GraphQL en lugar de interpolación) y mecanismo de desactivación (`CHAT_DISABLE_TWITCH_GQL`) en `docs/platforms.md`.
- **Validación en OBS Studio 32.2.2 real (`obs-browser` CEF 152.0.7977.83)**:
  - Verificación formal de integración con OBS Studio real (versión 32.2.2 en Linux/Hyprland) mediante OBS WebSocket v5 (`ws://127.0.0.1:4455`).
  - Script no destructivo `scripts/test_obs_validation.py` con restauración automática de escena/fuente previa (`try...finally`).
  - Fuente de tipo `browser_source` configurada a 1920x1080 @ 60 fps apuntando a la vista `/overlay/demo-stream` y `/overlay/gilraennr`.
  - **Transparencia y CSS**: Verificado canal alfa RGBA exacto (valor 0 fuera del área de mensajes, fondo transparente sin bloqueo sólido) y renderizado nítido de tipografía, avatares y badges (`obs_chat_live.png`).
  - **Multistream unificado**: Renderizado de mensajes combinados de Twitch (morado) y YouTube (rojo) en la misma feed con soporte UTF-8 completo y mitigación XSS estricta.
  - **Ciclo de vida y reconexión (DEV-13)**: Ocultación de fuente (`SetSceneItemEnabled: false`), reposo de 3 segundos y reactivación (`SetSceneItemEnabled: true`). Confirmada reconexión SSE instantánea y reemisión de snapshot sin mensajes duplicados (`obs_chat_reconnected.png`).
  - **Compatibilidad Linux/Wayland**: Documentado y validado que en entornos Wayland el motor CEF de OBS requiere `BrowserHWAccel=false` o compatibilidad Xwayland (`QT_QPA_PLATFORM=xcb`) para el compositing OSR de texturas de Chromium sobre el contexto OpenGL de OBS.

Pendientes (bloquean despliegue a producción):
- Pruebas de carga sostenida de 4 h y 24 h bajo REL-08.
- Kick diferido con prioridad -1 según directriz del operador.
- Aprobación formal de Kalista para publicación/despliegue en producción.

Rollback: volver al commit aprobado en main (`ae6ffb2`). Si se han persistido perfiles locales en disco mediante `CHAT_CONFIG` durante la ejecución de esta versión, es obligatorio limpiar o eliminar los campos `"linked_youtube"` en la raíz de cada perfil y `"login"` dentro de las fuentes de Twitch antes de reiniciar el proceso, ya que el esquema de validación estricto de `ae6ffb2` rechaza claves no reconocidas durante el arranque y detendría el servicio. No hay migraciones de base de datos ni datos de estado incompatibles.

