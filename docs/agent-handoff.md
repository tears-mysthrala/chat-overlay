# Handoff F2 — issue #13

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/13
- Rama: `feat/13-twitch-youtube-discovery`
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/13-twitch-youtube-discovery`
- PR previa: https://github.com/tears-mysthrala/chat-overlay/pull/12 (MERGED en main `ae6ffb2`).
- Autorizado: F2 Autodetección y vinculación de canal de YouTube desde Twitch para perfiles unificados (solicitado por operador).

Evidencias operativas y técnicas en esta entrega:
- **Autodetección de YouTube desde Twitch (`ChatOverlay.Resolver`)**:
  - Detección automatizada mediante consulta a la API pública GraphQL de Twitch (`https://gql.twitch.tv/gql`, social links del broadcaster) con fallback de parsing sobre la biografía/descripción (`description`) del usuario de Twitch obtenida en Helix.
  - Validación de red en `ChatOverlay.Net`: adición de `gql.twitch.tv` a la lista de hosts permitidos (`@hosts`) con control estricto de IP pública y límites de respuesta (256 KiB).
  - Comprobado en vivo contra perfiles reales:
    - `gilraennr` -> resuelto enlace de YouTube `https://www.youtube.com/channel/UCFUOHZSB9UdNRkjSBx3fpOQ`.
    - `revenant` -> resuelto enlace de YouTube `https://www.youtube.com/@REVENANT_Gameplays`.
- **Integración y supervisión en perfiles unificados (`ChatOverlay.Profiles` y `ChatOverlay.Config`)**:
  - Esquema ampliado de perfiles con campo opcional y validado `"linked_youtube"` (`<= 2048` caracteres).
  - Al añadir un canal de Twitch (`resolve_target_with_meta/2`): si el canal de YouTube detectado está emitiendo en directo, se fusiona automáticamente la fuente de YouTube generando una feed multistream unificada de inmediato. Si no está en directo, se guarda la referencia en `linked_youtube` sin bloquear ni dar error.
  - Sincronización en caliente (`sync_youtube/2`): busca emisiones en directo activas en el canal de YouTube asociado e incorpora la fuente de YouTube en tiempo de ejecución, actualizando el store y supervisión de workers sin interrumpir la conexión de Twitch.
- **Endpoints de API REST (`ChatOverlay.Web`)**:
  - `POST /api/profiles/:handle/sync-youtube`: permite al frontend solicitar la sincronización en vivo del canal de YouTube asociado. Protegido con validación de cabecera Origin y Content-Type JSON.
  - `POST /api/resolve`: enriquecido para devolver metadatos con el estado de YouTube (`discovered_youtube_url`, `youtube_live`).
- **Panel de control UI (`priv/static/app.js`, `priv/static/app.css`)**:
  - Indicador visual (badge) para canales de Twitch que tienen un canal de YouTube vinculado pero sin emisión activa.
  - Botón "▶ Sincronizar directo YouTube" para comprobar y conectar el chat de YouTube con un solo clic en cuanto el creador empiece directo.
  - Notificaciones en español sobre el estado de la vinculación y sincronización.
- **Suite de pruebas**:
  - 76 tests PASS (4 nuevos tests cubriendo detección de enlaces, preservación de `linked_youtube`, endpoint de sincronización y mitigación CSRF/Origin).
  - 0 advertencias de compilación (`mix compile --warnings-as-errors`).
  - Formato verificado con `mix format --check-formatted`.

Pendientes (bloquean cierre de #4 y despliegue):
- Validación en OBS Studio real con fuente navegador (transparencia, CSS y ciclo de vida de conexión al ocultar/mostrar fuente); no sustituir por Chromium para el cierre formal de la puerta.
- Pruebas de carga sostenida de 4 h y 24 h bajo REL-08.
- Kick diferido con prioridad -1 según directriz del operador.
- Aprobación formal de Kalista para publicación/despliegue.

Rollback: volver al commit aprobado en main (`ae6ffb2`); no hay migraciones ni datos durables.

