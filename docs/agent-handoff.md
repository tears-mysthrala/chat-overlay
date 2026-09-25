# Handoff F1 — issue #4

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/4
- Rama: `feat/4-live-validation`.
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/4-live-validation`.
- PR: https://github.com/tears-mysthrala/chat-overlay/pull/8 (OPEN, isDraft=false verificado).
- Autorizado: F1 base completado y mergeado en main (PR #5 y PR #7). Trabajo en puertas de validación en vivo para #4.

Implementados en esta entrega:
- Soporte para autenticación en YouTube Data API v3 mediante cabecera HTTP `X-Goog-Api-Key` cuando la credencial inicia por `AIza` (API Key de Google Cloud), manteniendo compatibilidad con tokens Bearer OAuth (`ya29...`).
- Prueba de regresión en `test/connectors_test.exs`.
- 53 tests PASS en `mix check`, sin advertencias.
- Identificadores de canal de Twitch y YouTube resueltos para `gilraennr`:
  - Twitch broadcaster ID: `39755457`, user ID: `38210456`, client ID: `gp762nuuoqcoxypju8c569th9wz7q5`.
  - YouTube channel ID: `UCFUOHZSB9UdNRkjSBx3fpOQ`.

Pendientes (bloquean cierre de #4 y despliegue):
- Configuración en entorno local de token de Twitch con scope `user:read:chat`.
- Validación en vivo con streaming real / live chat activo en YouTube y Twitch.
- Validación en OBS Studio real con fuente navegador (transparencia, CSS y ciclo de vida de conexión al ocultar/mostrar fuente).
- Pruebas de estabilidad de 4 h y 24 h bajo REL-08.
- Aprobación formal de Kalista para publicación/despliegue.

Rollback: revertir los commits de la PR #8 o volver a main; no hay migraciones ni datos durables.
