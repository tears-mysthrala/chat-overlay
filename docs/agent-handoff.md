# Handoff F1 — issue #4

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/4
- Rama: `docs/4-live-evidence`.
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/4-live-validation`.
- PR previa: https://github.com/tears-mysthrala/chat-overlay/pull/8 (MERGED en main `ce3d5a8`).
- Autorizado: F1 base completado y mergeado en main (PR #5, PR #7 y PR #8). Trabajo en puertas de validación en vivo para #4.

Evidencias operativas validadas en esta entrega:
- **Validación en vivo de Twitch completada**:
  - Broadcaster `gilraennr` (`39755457`), usuario autorizado `tearsmysthrala` (`38210456`), client ID `gp762nuuoqcoxypju8c569th9wz7q5`.
  - Token OAuth validado exitosamente contra endpoint oficial con scope `user:read:chat`.
  - Conexión WebSocket EventSub establecida con suscripciones aceptadas por Helix API (HTTP 202).
  - Recepción de mensaje real en vivo (`TearsMysthrala: test`) a las 10:34:02 UTC con latencia upstream -> cliente medida en ~250 ms.
  - Renderizado verificado en Chromium tanto en vista de gestión (`/reader/gilraennr`) como en vista transparente superpuesta (`/overlay/gilraennr`).
- **Estabilidad de proceso observada**:
  - Proceso BEAM activo de forma ininterrumpida durante más de 67 horas (2 días y 19 horas) manteniendo estado `available`, reconexiones WebSocket, keepalives y heartbeats periódicos de Twitch.
  - Métricas de recursos: RSS estable de ~9.7 MB, 0.0% CPU, 0 fugas de memoria o descriptores observados. Las pruebas formales de carga sostenida de 4 h (candidata F1) y 24 h (primer lanzamiento) bajo REL-08 con métricas activas de latencia y volumen permanecen como puertas requeridas.
- **53 tests PASS en `mix check`**, 0 fallos, 0 advertencias.
- **Auditoría de empaquetado**: Docker, CycloneDX 1.7 SBOM, OpenVEX y escáner Grype (0 hallazgos activos, 4 ignorados mediante excepciones aprobadas en `vex.openvex.json` sujetas a revisión periódica).

Pendientes (bloquean cierre de #4 y despliegue):
- Obtención de token OAuth 2.0 Bearer de YouTube con scope `https://www.googleapis.com/auth/youtube.readonly` e ID de chat activo (`live_chat_id`) correspondiente a una emisión en directo o programada en el canal de `gilraennr` (`UCFUOHZSB9UdNRkjSBx3fpOQ`).
- Validación en vivo con streaming real / live chat activo en YouTube.
- Validación en OBS Studio real con fuente navegador (transparencia, CSS y ciclo de vida de conexión al ocultar/mostrar fuente); no sustituir por Chromium para el cierre formal de la puerta.
- Pruebas de carga sostenida de 4 h y 24 h bajo REL-08.
- Kick diferido con prioridad -1 según directriz del operador.
- Aprobación formal de Kalista para publicación/despliegue.

Rollback: volver al commit aprobado en main; no hay migraciones ni datos durables.
