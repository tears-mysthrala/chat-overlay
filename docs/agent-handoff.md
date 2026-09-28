# Handoff F2.1 — issue #11

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/11
- Rama: `feat/11-dynamic-channels`
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/11-dynamic-channels`
- PR previa: https://github.com/tears-mysthrala/chat-overlay/pull/10 (MERGED en main `2c140af`).
- Autorizado: F2.1 Gestión dinámica en UI y resolución automática en caliente (aprobado por Kalista).

Evidencias operativas y técnicas en esta entrega:
- **Resolución automática de canales e introspección de tokens (`ChatOverlay.Resolver`)**:
  - Normalización robusta de slugs y targets de Twitch y YouTube (`clean_twitch_slug/1`, `clean_youtube_target/1`), admitiendo nombres de usuario (`revenant`), URLs completas o sin esquema (`twitch.tv/revenant`, `youtube.com/watch?v=...`, `youtu.be/...`), handles de YouTube (`@HAKODATELIVECAMERA`) y channel IDs (`UC...`).
  - Introspección automática del token OAuth de Twitch mediante `validate_twitch_token/1` contra `https://id.twitch.tv/oauth2/validate`, extrayendo automáticamente el `client_id` y `user_id` del token para la suscripción de EventSub sin necesidad de configuración manual adicional.
  - Resolución dinámica de usuarios de Twitch en Helix (`/helix/users?login=...` o `?id=...`) obteniendo el broadcaster user ID numérico en caliente.
  - Detección de directos activos en YouTube mediante búsqueda de transmisiones activas (`eventType=live`) o lectura directa de detalles de emisión (`videos?part=snippet,liveStreamingDetails`) extrayendo el `activeLiveChatId`.
- **Gestión dinámica de perfiles y supervisión en caliente (`ChatOverlay.Profiles`)**:
  - Funciones de ciclo de vida en runtime: `list/0`, `get/1`, `resolve_target/2`, `create_or_update/2` y `delete/1`.
  - Supervisión en caliente de procesos: al añadir un perfil se inician dinámicamente los procesos hijos en `ChatOverlay.Stores` (`Store.child_spec/1`) y `ChatOverlay.Sources` (`Source.child_spec/1`) vía `Supervisor.start_child/2`.
  - Soporte de multi-streaming: fusiona canales de distintas plataformas (Twitch + YouTube) bajo el mismo perfil sin duplicar procesos ni borrar fuentes existentes.
  - Eliminación en caliente: desmantela de forma segura el Store del perfil y detiene los workers de Sources que no estén compartidos por otros perfiles (`Supervisor.terminate_child/2` y `Supervisor.delete_child/2`).
  - Persistencia segura y atómica en `config/local-profiles.json` (o `CHAT_CONFIG`) mediante escritura temporal y rename atómico, sin guardar tokens ni secretos en archivos rastreados por Git.
- **Endpoints de API REST en `ChatOverlay.Web`**:
  - `GET /api/profiles`: devuelve la lista de perfiles configurados con sus plataformas activas y URLs de lector y overlay. Nunca expone credenciales ni tokens (SEC-06).
  - `POST /api/profiles`: acepta peticiones JSON para crear o actualizar canales en caliente con resolución automática.
  - `POST /api/resolve`: permite resolver y validar canales antes de guardarlos.
  - `DELETE /api/profiles/:handle`: elimina perfiles y desmantela sus procesos supervisados.
  - Límites de seguridad aplicados: lectura acotada a 64 KB en peticiones para evitar ataques de denegación de servicio.
- **Panel de creador en frontend (`priv/static/index.html`, `priv/static/app.js`, `priv/static/app.css`)**:
  - Panel interactivo en `/` que muestra los canales activos, badges de plataforma (Twitch, YouTube, Kick) y botones de acción ("Abrir Lector", "Copiar Overlay OBS", "Eliminar").
  - Formulario integrado para añadir streamers en caliente pegando su usuario o URL, con feedback visual de progreso y errores legibles en español.
- **Validación en vivo completada**:
  - Servidor iniciado en puerto 4101 con tokens reales de Twitch y YouTube.
  - Adición dinámica de Twitch (`https://twitch.tv/revenant`): resuelto broadcaster `38446500`, iniciado store y worker EventSub en caliente, recepción de mensajes de chat en directo verificada vía SSE `/events/revenant`.
  - Adición dinámica de YouTube (`https://www.youtube.com/@HAKODATELIVECAMERA`): resuelto channel ID `UCynX4LJTQ_H7_KPy7QiIS2A` y `live_chat_id`, verificado estado `available` en vivo.
  - Eliminación dinámica de perfiles verificada con parada de procesos en el Registry y actualización de la lista.
- **Suite de pruebas y robustez**:
  - 72 tests PASS (16 tests dedicados que cubren `Resolver`, `Profiles`, supervisión en caliente, serialización GenServer concurrente, endpoints de API Web y mitigación CSRF/Origin).
  - Serialización de mutaciones de perfiles a través del GenServer `ChatOverlay.Profiles` para eliminar condiciones de carrera concurrentes.
  - Validación de cabecera Origin y Content-Type `application/json` en endpoints mutantes de API.
  - Limpieza acotada de workers de fuentes (`ChatOverlay.Sources`) al eliminar o reemplazar perfiles.
  - 0 fallos, 0 advertencias de compilación (`mix compile --warnings-as-errors`).
  - Formato de código verificado con `mix format --check-formatted`.

Pendientes (bloquean cierre de #4 y despliegue):
- Validación en OBS Studio real con fuente navegador (transparencia, CSS y ciclo de vida de conexión al ocultar/mostrar fuente); no sustituir por Chromium para el cierre formal de la puerta.
- Pruebas de carga sostenida de 4 h y 24 h bajo REL-08.
- Kick diferido con prioridad -1 según directriz del operador.
- Aprobación formal de Kalista para publicación/despliegue.

Rollback: volver al commit aprobado en main (`2c140af`); no hay migraciones ni datos durables.
