# Aceptación de recuperación y rotación — 2026-10-09

Refs #40, #55. Base65a22e5d6d4612d5127175780ea89d62d47e0105.
Esta unidad concilia herramientas/procedimiento y ensayos sintéticos; no rota
claves reales ni sube copias privadas ni detiene producción.

## Criterios y resultados

Formato/key_id/AAD, custodia fuera de Git y separación clave/copia están en
[recovery.md](../../../recovery.md). Version1 exterior y credenciales v1 se
validan antes de escribir; salidas privadas0600, sin overwrite ni symlinks.
La rotación exige clave diferente y vuelve a cifrar todas las credenciales
con AAD ligado a propietario/proveedor, conservando perfiles/permisos/ledger.

RecoveryTest:6 PASS seed0, imagen chat-overlay:70-validation, rednone,
2CPU/1GiB/128PIDs,+S2:2. Backup/restore sintético conserva datos exactos y
rotación conserva permisos/aislamiento A-B. Clave incorrecta, corrupción,
copia truncada/interrumpida, credencial dañada, ruta/disco no escribible,
symlink, destino existente, clave no privada y versión desconocida fallan
sin salida aceptable ni filtrado de plaintext.

Pruebas auxiliares Linux backup:7 PASS en python:3.13-alpine sin red y
checkoutreadonly. Admisión de bundle y cleanup de backup con comandos
sintéticos; no se presentan los stubs como prueba criptográfica real.
La prueba criptográfica CMS y restauración real offline de PostgreSQL/medios
constan en 2026-10-07-ops-recovery.md; no se repitieron hoy ni se extrajeron secretos.

Procedimiento: workers detenidos antes de sustituir datos/clave, validar copia
antes de activar y conservar par antiguo para rollback. Cambiar clave invalida
sesiones/OAuth pendiente/tickets de carga: reautenticar/reintentar. Capabilities
OBS no se revocan por rotar la clave; incidente exige regenerarlas por separado.
No se ejecutaron esas operaciones sobre usuarios reales.

## Límites operativos

La copia remota tiene existencia/sincronización verificadas históricamente;
descarga independiente403 sigue NOT TESTED. Custodia redundante de clave fuera
de este PC y periodicidad de backup no se acreditan por estos tests: operación
continua pendiente #38. Este cierre acredita criterios de herramienta/ensayo/
procedimiento #40; no cierra disponibilidad del servicio ni #38 ni #55.
CI de conciliación pendiente. Rollback de esta PR es documental.
