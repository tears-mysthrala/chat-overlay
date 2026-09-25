# Handoff F1 — issue #4

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/4
- Rama: `feat/4-live-validation`.
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/4-live-validation`.
- PR: https://github.com/tears-mysthrala/chat-overlay/pull/8 (OPEN, isDraft=false verificado).
- Autorizado: F1 base completado y mergeado en main (PR #5 y PR #7). Trabajo en puertas de validación en vivo para #4.

Preparación operativa en esta entrega:
- Confirmado y documentado que YouTube Data API v3 (`liveChatMessages.list`) exige autorización OAuth 2.0 de usuario mediante token Bearer (`https://www.googleapis.com/auth/youtube.readonly`), conforme a las especificaciones oficiales de Google y SEC-06. Se mantiene estrictamente el transporte OAuth Bearer sin atajos de claves sintéticas no soportadas por la API de live chat.
- Añadida prueba de caso negativo de autorización (401 Unauthorized) en `test/connectors_test.exs` que verifica detención segura con `{:stop, :configuration_error}`.
- 53 tests PASS en `mix check`, sin advertencias.
- Identificadores oficiales resueltos para `gilraennr`:
  - Twitch broadcaster ID: `39755457`, user ID: `38210456`, client ID: `gp762nuuoqcoxypju8c569th9wz7q5`.
  - YouTube channel ID: `UCFUOHZSB9UdNRkjSBx3fpOQ`.

Pendientes (bloquean cierre de #4 y despliegue):
- Configuración en entorno local de token de Twitch con scope `user:read:chat`.
- Obtención de token OAuth 2.0 Bearer de YouTube con scope `https://www.googleapis.com/auth/youtube.readonly` e ID de chat activo (`live_chat_id`).
- Validación en vivo con streaming real / live chat activo en YouTube y Twitch.
- Validación en OBS Studio real con fuente navegador (transparencia, CSS y ciclo de vida de conexión al ocultar/mostrar fuente).
- Pruebas de estabilidad de 4 h y 24 h bajo REL-08.
- Aprobación formal de Kalista para publicación/despliegue.

Rollback: revertir los commits de la PR #8 o volver a main; no hay migraciones ni datos durables.
