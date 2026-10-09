# Aceptación de persistencia — 2026-10-09

Refs #51, #55. Base32e18b28af17533a0cdbad70a2951c6891228db7.
Backend real PostgreSQL/RLS, no equivalencia ficticia con JSON.
La separación frontend/custodio desplegada se documenta en ADR0008 y los
registros de PR67. Este cierre no acredita toda la deuda operativa de #39/#42.

## Pruebas ejecutadas

Proyecto sintético overlay51-acceptance-20261009, red interna sin puertos,
PostgreSQL18.6 pin de compose.postgres-local.yml. Migración ejecutada como
owner overlay_migrator; runtime separado overlay_runtime. Suite sobre imagen
chat-overlay:70-validation:26 PASS seed0 y26 PASS seed424242, más arranque
completo, mutación duradera y reinicio PASS. Informes ExUnit adjuntos.

rls_test.exs verifica roles efectivos, FORCE RLS, ausencia de contexto,
WITH CHECK, denegación A/B y limpieza de contexto en commit/rollback/excepción.
La batería de producto falla escrituras create/update/delete/token/media/quota/
link/unlink al revocar permisos SQL: ningún éxito falso, ningún cambio de
runtime/durable y ningún fallback JSON. Incluye rollback transaccional,
concurrencia serializada, snapshot obsoleto y carga durable tras reinicio.
Exportación/migración offline y rollback conservan datos privados exactos,
cuentas cifradas, versiones, capability y ledger.

En contenedor sin red2CPU/1GiB/128PIDs,+S2:2: profile_persistence_test,
profile_storage_test y profiles_oauth_test suman18 PASS seed0. Cubren fallo de
ruta no escribible, reload/permisos privados, exportación concurrente y symlinks.
JSON es backend demo/export explícito; no se presenta como RLS de producción.

Se comprobó ausencia previa del proyecto sintético antes de crearlo.
PostgreSQL se detuvo al terminar; volumen de fixtures retenido, sin afectar otros
servicios ni la carga24h. No se usaron cuentas ni datos reales.

## Entrega y límites

Implementación ya integrada por PR56/65/67; esta unidad concilia aceptación.
CI pendiente del registro. No cambia backend, privilegios de producción ni datos.
Revert documental como rollback; no repetir migraciones de producción.
