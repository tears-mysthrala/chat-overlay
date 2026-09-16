# Verificación F0

| Requisito | Evidencia | Estado |
| --- | --- | --- |
| DEV-01/04 | Issue #1, rama `chore/1-bootstrap`, worktree dedicado | Hecho |
| ARCH-01 | `mix.exs`, OTP Application, sin dependencias Mix | Implementado; ejecución local pendiente por toolchain |
| REL-01 | `docs/event-contract.md` | Documentado; implementación F1 pendiente |
| SEC-02/03/04/10 | `docs/threat-model.md`, sin secretos ni entradas externas | Revisado para F0 |
| SUP-01/02/03 | `docs/dependencies.md` | Inventario inicial; SBOM pendiente |
| DEV-12 | `.github/workflows/ci.yml`, `mix check` | Configurado; CI remoto pendiente |
| DEV-15 | README, este documento y handoff | En curso hasta PR/revisión humana |

## Evidencia ejecutada

- Inspección de Git, remoto, rama predeterminada, issue y worktree: realizada.
- `mix check`: no ejecutado; el entorno local no tiene `erl.exe` disponible aunque existen los wrappers de Elixir/Mix.
- CI remoto: pendiente de abrir PR.
- Validación de plataformas, OBS, navegador, carga y seguridad F1: fuera de alcance.
