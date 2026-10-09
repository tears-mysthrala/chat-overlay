# Despliegue

- [Corte custodio e interfaz 2026-10-08](runs/2026-10-08-custodian-cutover-ui.md): separación desplegada y firewall/secretos/datos verificados; diseño local en validación, OAuth/OBS posteriores al corte pendientes.

- [Custodio privado 2026-10-07](runs/2026-10-07-private-custodian.md): ADR0008
  aprobado e integrado por PR #67; historial de validación local y revisión.

- [Recuperación 2026-10-07](runs/2026-10-07-ops-recovery.md): backup real cifrado
  sincronizado a Drive, base/medios/cuentas restaurados sin red; ARCH06 y
  mantenimiento pendientes.

- [Publicación Benten 2026-10-07](runs/2026-10-07-public.md): HTTPS operativo,
  permisos/firewall verificados, banking preservado; OAuth/R2 pendientes.
- [Preparación Benten 2026-10-07](runs/2026-10-07.md): historial de provisionado
  privado y bloqueo inicial resuelto en el registro de publicación.
- [Procedimiento](procedure.md).
- [Lectores OAuth 2026-10-07](runs/2026-10-07-readers.md): validación local; revisión corregida y despliegue pendientes.

- [Reconciliación y cierre F2 2026-10-08](runs/2026-10-08-debt-closeout.md): PR68 desplegada, pruebas reales consolidadas, backlog actualizado, smoke de carga PASS y ejecución de4 h iniciada.

- [Carga sostenida 2026-10-09](runs/2026-10-09-soak.md): cuatro horas aceptadas;24 h en ejecución, sin resultado final.

- [CI exigible 2026-10-09](runs/2026-10-09-ci.md): protección aplicada; acciones Node24 y regresión local, CI remoto pendiente.

- [Aceptación preview 2026-10-09](runs/2026-10-09-preview-acceptance.md): seis regresiones PASS; CI final pendiente.

- [Aceptación disco local 2026-10-09](runs/2026-10-09-local-media-acceptance.md):24 pruebas de aplicación y12 de disco/coordinador PASS; evidencia operativa conciliada.

- [Aceptación persistencia 2026-10-09](runs/2026-10-09-persistence-acceptance.md):26 RLS PASS por semilla, boot/restart PASS y18 pruebas de persistencia PASS.
