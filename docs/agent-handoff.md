# Handoff F1 — issue #3

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/3
- Rama: `feat/3-f1-overlay`.
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/3-f1-overlay`.
- PR: https://github.com/tears-mysthrala/chat-overlay/pull/5 (OPEN, isDraft=false verificado).
- Autorizado: completar F0 y construir F1; Bandit/Mint aprobados. No merge ni despliegue.

Implementados: stores acotados, dedup/borrados/replay, supervisión y demanda, tres conectores oficiales, callback Kick firmado, SSE, lector/overlay estático, demo, contenedor limitado, CI e inventario/escaneo. README ofrece arranque local y docs/platforms.md la preparación real.

39 tests PASS en Linux (Elixir 1.20.4/OTP 29), sin advertencias de compilación. Atendidos hallazgos de revisión externa (CodeRabbit y Codex): headroom en Task.Supervisor, eliminación de local_sequence en deltas de replay SSE, espera activa con monitores para cierre de lectores en load.exs, reenvío de respuestas previas en error de stream de Mint, y validación de moderation_subscription_id en Kick. Carga de 60 s con 45.000/45.000 entregas y p95 51 ms. CI remota lanzada por la PR.

[Verificación](verification.md) y [registro](workflows/f1-delivery/runs/2026-09-20.md) distinguen pruebas locales de publicación. Hallazgos de imagen: **4 abiertos** (1 High, 3 Medium; 2 CVE); gate no verde. Canal público gilraennr indicado por la usuaria; no hay aplicaciones/API registradas. No hay validación de vivo/OBS/4 h/24 h.

Siguiente paso: revisión humana de PR y cierre de [#4](https://github.com/tears-mysthrala/chat-overlay/issues/4). No solicitar tokens en chat. No registrar apps ni publicar callback/túnel con la autorización de implementación local. Rollback: revertir los commits de la PR o volver al digest aprobado; no existen migraciones ni historial durable.
