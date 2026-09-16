# Handoff F0 — issue #1

- Issue: <https://github.com/tears-mysthrala/chat-overlay/issues/1>
- Rama: `chore/1-bootstrap`
- Worktree: `D:\github\chat-overlay-worktrees\1-bootstrap`
- PR: <https://github.com/tears-mysthrala/chat-overlay/pull/2> (draft; no se ha hecho merge).

## Cambios

Aplicación Elixir/OTP mínima, prueba de fase F0, README, workflow CI con permisos `contents: read`, contrato de eventos, arquitectura, threat model, dependencias, compliance y matriz de verificación.

## Pruebas

`mix check` pasa localmente con Elixir 1.20.4 y Erlang/OTP 29.0.6 usando el PATH de la instalación Scoop; resultado: 2 tests pasados. El PATH no se modificó globalmente. La CI queda configurada para repetir formato, tests y comprobación de trazabilidad en GitHub.

## Pendientes y riesgos

- Obtener revisión humana; la PR draft ya está abierta.
- Validar CI real y completar SBOM/licencias/escaneo.
- Crear issues separados para contrato ejecutable, simulador y validación técnica de plataformas.
- No se validaron plataformas en vivo; no se conectaron cuentas, no se desplegó y no se modificó DNS/túnel.

## Rollback

Revertir la PR; no hay migraciones, secretos ni datos durables.
