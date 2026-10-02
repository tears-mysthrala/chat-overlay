# ADR 0004 — Persistencia de perfiles F2 y límites del aislamiento

Estado: propuesta para revisión de Kalista; Refs #51. No aprueba una sustitución
silenciosa de SEC-13 ni acredita equivalencia con PostgreSQL/RLS.

## Estado implementado

El servicio admite como máximo diez perfiles y un documento de 64 KiB. Un único
GenServer `Profiles` serializa mutaciones. El almacenamiento actual es JSON local:
capability tokens se conservan como hashes y credenciales recuperables como AEAD.
La identidad y autorización por perfil se verifican en las rutas HTTP antes de
acceder a operaciones internas; `Config` y `Profiles` no son una frontera contra
código arbitrario dentro de la misma VM.

Guardar exige validar y persistir primero. El documento se escribe en un directorio
temporal exclusivo y privado (0700), con archivo 0600, sincronización del archivo
y renombrado en el mismo filesystem. Un error conserva estado previo, workers y
accesos y se devuelve al llamante. El tamaño máximo coincide con el del loader.
La atomicidad de rename evita documentos parcialmente visibles; no se garantiza
resistencia a corte eléctrico sin sincronización de directorio ni almacenamiento
fiable. No se soportan múltiples nodos escritores sobre el mismo documento.

Excepción explícita: una credencial invalidada/rotada por upstream puede marcarse
`reauth_required` en memoria aunque falle el disco, devolviendo error de persistencia.
Es una medida de bloqueo temporal, no una escritura exitosa. Recuperación después
de esa situación requiere revisión/reautenticación antes de arrancar con el documento
anterior; #40 especifica el procedimiento.

## Comparación y decisión pendiente

| Propiedad | JSON actual | Referencia PostgreSQL/RLS |
| --- | --- | --- |
| Autorización HTTP A/B | Pruebas negativas de sesión y perfil | También necesaria |
| Mutaciones concurrentes | Un escritor serial; archivo completo | Transacciones y concurrencia de base |
| Aislamiento por fila independiente de filtros de aplicación | No disponible | Políticas RLS con rol/pool real correctamente configurado |
| Aplicación plenamente comprometida | Puede acceder al documento y claves de su proceso | RLS tampoco protege contextos que el rol de aplicación pueda elegir legítimamente |
| Varios nodos escritores | No soportado | Posible con diseño y pruebas adicionales |

Se conserva el backend existente durante la corrección de atomicidad. Para aceptar
SEC-13 en una publicación F2, Kalista debe aprobar una arquitectura que demuestre
el aislamiento exigido, o autorizar PostgreSQL/RLS y su dependencia/migración. Este
ADR **no declara** que filtros en Elixir equivalgan a RLS. El punto de decisión
permanece abierto en #51 y se incorpora a la evaluación de #42/#39.

## Verificación y rollback

`test/profile_persistence_test.exs` cubre create/update/delete, capability token,
multimedia/cuota, link/unlink ante fallos de disco; conserva runtime, documento,
store y acceso vigente, y comprueba concurrencia y recarga.
`test/profile_storage_test.exs` verifica tamaño y reemplazo de symlink sin modificar
el destino. Las regresiones existentes de tokens prueban el bloqueo tras rotación
no persistida. Revert del commit restaura el comportamiento anterior, que puede
devolver éxito sin guardar; no se recomienda como solución al fallo de disco.
