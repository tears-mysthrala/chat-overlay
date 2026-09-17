# Verificación F0

| Requisito | Evidencia | Estado |
| --- | --- | --- |
| DEV-01/04 | Issue #1, rama `chore/1-bootstrap`, worktree dedicado | Hecho |
| ARCH-01 | `mix.exs`, OTP Application, sin dependencias Mix | Implementado; `mix check` local PASS |
| REL-01 | `docs/event-contract.md` | Documentado; implementación F1 pendiente |
| SEC-02/03/04/10 | `docs/threat-model.md`, sin secretos ni entradas externas | Revisado para F0 |
| SUP-01/02/03 | `docs/dependencies.md` | Inventario inicial; SBOM pendiente |
| DEV-12 | `.github/workflows/ci.yml`, `mix check`, CI run completado | Configurado; CI remoto PASS |
| DEV-15 | README, este documento, handoff y PR draft #2 | En curso hasta revisión humana |

## Evidencia ejecutada

- Inspección de Git, remoto, rama predeterminada, issue y worktree: realizada.
- `mix check`: PASS; Elixir 1.20.4/Erlang OTP 29.0.6, 2 tests pasados.
- CI remoto: PASS en la PR draft #2.
- Validación de plataformas, OBS, navegador, carga y seguridad F1: fuera de alcance.
