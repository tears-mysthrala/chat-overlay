# Handoff F1 — issue #3

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/3
- Rama: `feat/3-f1-overlay`.
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/3-f1-overlay`.
- PR: https://github.com/tears-mysthrala/chat-overlay/pull/5 (OPEN, isDraft=false verificado).
- Autorizado: completar F0 y construir F1; Bandit/Mint aprobados. No merge ni despliegue.

Implementados: stores acotados, dedup/borrados/replay, supervisión y demanda, tres conectores oficiales, callback Kick firmado, SSE, lector/overlay estático, demo, contenedor limitado, CI e inventario/escaneo. README ofrece arranque local y docs/platforms.md la preparación real.

50 tests PASS en Linux (Elixir 1.20.4/OTP 29, incluyendo suite de #6), sin advertencias de compilación. Atendidos hallazgos de revisión externa (CodeRabbit, Greptile y Codex): headroom en Task.Supervisor, eliminación de local_sequence en deltas de replay SSE, espera activa con monitores para cierre de lectores en load.exs, reenvío de respuestas previas en error de stream de Mint, validación de moderation_subscription_id en Kick, soporte de worktrees y captura de OIDs en hooks, limitación de frecuencia para source_state en Store, reset de backoff para workers estables en Source, y verificación estricta de fecha de caducidad en VEX. Carga de 60 s con 45.000/45.000 entregas y p95 51 ms. CI remota en verde.

[Verificación](verification.md) y [registro](workflows/f1-delivery/runs/2026-09-20.md) distinguen pruebas locales de publicación. Hallazgos de imagen: **0 activos** (4 ignorados bajo dispensa aprobada por Kalista en `vex.openvex.json`, revisión debida 2026-10-21; componentes zlib/busybox permanecen sin parche upstream); gate verde. Canal público gilraennr indicado por la usuaria; no hay aplicaciones/API registradas. No hay validación de vivo/OBS/4 h/24 h.

Siguiente paso: revisión humana de PR y cierre de [#4](https://github.com/tears-mysthrala/chat-overlay/issues/4). No solicitar tokens en chat. No registrar apps ni publicar callback/túnel con la autorización de implementación local. Rollback: revertir los commits de la PR o volver al digest aprobado; no existen migraciones ni historial durable.

---

# Handoff #6 — fragmentos y emotes de Twitch (apilado sobre #3)

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/6
- Rama: `feat/6-emotes` (base `feat/3-f1-overlay` hasta el merge de #3).
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/6-emotes`.
- PR: https://github.com/tears-mysthrala/chat-overlay/pull/7 (OPEN, lista para revisión, nunca draft).

Cambios: esquema `fragments` opcional/retrocompatible en `ChatOverlay.Event`, extracción en `Adapters.twitch` con degradado a texto (nunca se pierde el mensaje), render DOM seguro en `app.js`, CSP `img-src` con CDN oficial de Twitch, regresiones (49 tests PASS) y docs (`event-contract.md`, `platforms.md`).

Probado: `mix check` 49 PASS sin advertencias; `scan_secrets.py` sin fugas; `security_static.py` 0 hallazgos; `check_traceability.py` OK #6. Pendiente (puerta #4): verificación en vivo con el canal del operador, OBS real y pruebas 4 h/24 h. YouTube/Kick quedan en texto plano. Rollback: revertir los commits de la PR #7.
