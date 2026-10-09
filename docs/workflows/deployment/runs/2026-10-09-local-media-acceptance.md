# Aceptación de almacenamiento local — 2026-10-09

Refs #62, #55. Base54671c1e78478794b2c7f3fd73ea3a008aacbd35.
No cambia producto, configuración, dependencias ni producción.

## Validación ejecutada

FedoraLinux-43, datos sintéticos: test_local_media_store.py8 PASS,
test_local_media_e2e.py1 PASS y test_compact_local_media.py3 PASS.
Disk/HTTP privado: presupuesto compartido, inmutabilidad/reinicio, tombstone
previa a carga, originales inaccesibles, autenticación, symlink/traversal,
bytes alterados y huérfanos. E2E usa bytes PNG y WAV reales y decodificador
sin red: publicación/hash, reinicio, borrado y rechazo de carga tardía.
Mantenimiento preserva bytes vivos y rechaza estado ambiguo o escritores activos.

Primer E2E falló porque Fedora usa otro daemon sin esa imagen. Se transfirió el
bundle de Desktop89432cb3, importado como8274808e. Se compararon por inspección
RootFS, Config, Architecture y Os: igualdad exacta en los cuatro campos.
La prueba funcional usa8274808e; no sustituye89432cb3 en despliegue/VEX.
No se tocó el contenedor de carga24h de Docker Desktop.

Aplicación en chat-overlay:70-validation, red none,2CPU/1GiB/128PIDs,+S2:2,
test/ actual montado readonly:24 pruebas PASS seed0 entre local_media_test,
media_ledger_test y media_pipeline_test. Cubren reserva, autorización por perfil,
bytes exactos/prueba de carga, cuotas/concurrencia/replay, MIME y publicación,
revocación/borrado, hash y rechazo de inventario con backend mezclado.

## Evidencia operativa y límites

ADR0006 describe límites256MiB y reserva2GiB; rutas privadas y rollback.
El registro 2026-10-07-local-media.md conserva verificación de permisos700/600,
firewall/control privado y originales404; copia previa y despliegue acotado.
PR65 integra el backend y PR68 conserva el despliegue. La subida desde panel
se recoge en ese registro; representación imagen/audio en OBS y confirmación
del operador quedan en 2026-10-07-obs-preview.md y el corte posterior a PR68.
El cierre de #64 por PR76 completa la aceptación del preview manual.
Esto no acredita eventos automáticos ni almacenamiento R2 contratado.
Las validaciones históricas no se presentan como repetidas hoy.

Rollback de esta entrega: revert documental; no elimina datos.
CI de esta conciliación pendiente. #49 mantiene su aceptación global de
cuarentena y #63 el escalado pendiente de originales grandes.
