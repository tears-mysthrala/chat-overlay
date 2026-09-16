# Handoff F0 — issue #1

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/1
- Rama: `chore/1-bootstrap`
- Worktree: `D:\github\chat-overlay-worktrees\1-bootstrap`
- PR: pendiente; no se ha hecho merge.

## Cambios

Aplicación Elixir/OTP mínima, prueba de fase F0, README, workflow CI con permisos `contents: read`, contrato de eventos, arquitectura, threat model, dependencias, compliance y matriz de verificación.

## Pruebas

No se pudo ejecutar `mix check`: el entorno Windows tiene wrappers de Elixir/Mix, pero no encuentra `erl.exe`. La CI queda configurada para ejecutar formato, tests y comprobación de trazabilidad en GitHub.

## Pendientes y riesgos

- Instalar/seleccionar Erlang/OTP compatible y ejecutar `mix check` localmente.
- Abrir PR enlazada y obtener revisión humana.
- Validar CI real, revisar el pin de la acción checkout y completar SBOM/licencias/escaneo.
- Crear issues separados para contrato ejecutable, simulador y validación técnica de plataformas.
- No se validaron plataformas en vivo; no se conectaron cuentas, no se desplegó y no se modificó DNS/túnel.

## Rollback

Revertir la PR; no hay migraciones, secretos ni datos durables.
