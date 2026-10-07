# PostgreSQL local — unidad A, Refs #51

Autorización expresa del usuario del 05-10-2026: ADR0005 A/B, implementación y
validación local; esta unidad implementa A. Sin cuentas reales ni despliegue.

## Integración y frontera

`CHAT_STORAGE=postgres` selecciona el backend del producto: el supervisor inicia
dos pools, valida roles/esquema/grants y carga perfiles/cuentas/inventario antes de
iniciar Stores, Sources y HTTP. No importa JSON ni crea esquema al arrancar. Una
configuración inválida, DB no disponible o privilegios incorrectos impiden arrancar.
La release exige seleccionar `CHAT_STORAGE`; el ejemplo Compose declara
`json_demo`. JSON sigue disponible para demo y recuperación offline y no equivale
a RLS. Nunca se elige tras un error PostgreSQL.

El escritor existente `Profiles` serializa create/update/delete, capability,
media, cuotas, link/unlink, refresh/reauth y las fases de cleanup. Compara el valor
durable anterior y escribe el delta de perfiles/cuentas/objetos en una transacción.
Solo actualiza memoria después del commit. Un advisory lock fijo serializa los
escritores compatibles; un valor anterior obsoleto devuelve `stale_storage`.
SQL parametrizado con Postgrex; sin Ecto ni biblioteca JSON adicional.

| Identidad | Permisos efectivos |
| --- | --- |
| `overlay_migrator` | Propietario separado; DDL offline. No pertenece al runtime. |
| `overlay_runtime` | SELECT/INSERT/UPDATE/DELETE con RLS y FORCE RLS en las tres tablas; sin ownership, membresías, superuser, BYPASSRLS, CREATE, TRUNCATE, TRIGGER ni REFERENCES. |
| `overlay_bootstrap` | SELECT global para arranque/source coordination/export; sin escrituras, DDL ni membresías. Política SELECT explícita, no BYPASSRLS. |

El runtime aplica `USING` y `WITH CHECK` sobre `handle`. Cada contexto se establece
con `set_config(..., true)` **dentro de la transacción**; no queda en el pool.
Sin contexto, SELECT no devuelve filas, UPDATE/DELETE no afectan filas e INSERT
se rechaza. Las cuentas están separadas del cuerpo de perfil y contienen el mismo
ciphertext y versiones originales; los objetos retirados sobreviven a DELETE de
perfil hasta confirmación remota.

`Web.call` comienza sin autorización. Solo `Session.authorize`, la autorización
de creación o el callback OAuth después de verificar propiedad conceden el handle;
ese contexto se transmite al GenServer y se limita al delta escrito. Se limpia
con `after`, incluso ante excepción. No hay cabecera, parámetro, ruta ni cuerpo
HTTP para elegir SQL, rol o contexto DB. Las tareas de tokens/source/cleanup y las
herramientas offline usan la identidad lógica interna de servicio. No cambia las
reglas de autorización existentes del modo demo local.

**Límites ARCH-06:** ambos pools y la caché privada siguen dentro de la misma VM
BEAM. Código comprometido dentro de esa VM puede usar las credenciales de lectura
global o elegir contextos runtime. RLS protege consultas ordinarias y errores de
ámbito; no establece la separación de procesos/contenedores de #39. Un único
coordinador de producto activo está soportado: varias instancias con cachés
independientes necesitan coordinación global adicional para límites y frescura.
No publicar hasta resolver esas fronteras y los restantes gates F2.

## Configuración preparada, sin despliegue

La release usa `CHAT_STORAGE=postgres`, `CHAT_DB_HOST`, `CHAT_DB_PORT` (5432),
`CHAT_DB_NAME`, `CHAT_DB_RUNTIME_PASSWORD` y `CHAT_DB_BOOTSTRAP_PASSWORD`.
Identidades fijadas; pools de dos conexiones. TLS con verificación de peer, raíces
del sistema y SNI del hostname. `CHAT_CONFIG` junto con postgres se rechaza.
Certificado/CA, secretos, grants y backup reales requieren preparación del operador;
no se han configurado. Los tests declaran `ssl: false` únicamente en su red Docker
sintética sin puertos publicados; no es un fallback de producción.

## Migración y rollback offline

1. Detener todos los escritores y la aplicación; conservar una **copia** privada
   del JSON y la clave de cifrado fuera del repositorio. Revisar versión/esquema.
2. Provisionar identidades separadas sin memberships. Ejecutar
   `priv/postgres/001_rls.sql` offline como propietario, no como runtime. El fichero
   no aprovisiona contraseñas ni se ejecuta automáticamente.
3. Usar `scripts/postgres_transfer.exs` con `mix run --no-start` y `import-copy`
   sobre la copia. Solo arranca Postgrex, sin HTTP, fuentes, refresh ni cleanup.
   Rechaza destino no vacío, valida límites, importa con runtime/RLS y compara
   exportación con la estructura canónica; informa conteos y SHA-256. Conserva
   ciphertext, account_version, capability hashes y todo el ledger sin descifrar.
4. Revisar el resultado antes del cambio de origen. La copia original no cambia.
   Antes de nuevas escrituras, se puede regresar a esa copia intacta.
5. **Después de escribir en DB no restaurar el JSON antiguo.** Detener escritores,
   usar `export-copy` hacia un nombre nuevo, validar carga/conteos/digest y conciliar
   cleanup y objetos pendientes con el estado externo antes de volver a JSON.
   La exportación lleva modo 0600; no sobrescribe una salida existente. La vuelta
   a JSON sigue sin acreditar RLS y no habilita publicación.

Los digests comparan estructuras canónicas mediante serialización determinista
OTP y SHA-256, no bytes JSON ni orden original de listas. Las herramientas son
offline y requieren exclusividad del operador. No son un backup ante caída del
host ni una reconciliación R2 real. Revocaciones de sesión ETS conservan el límite
histórico de reinicio del producto; esta unidad no rediseña sesiones.

## Pruebas reproducibles

Construir `docker build --target validation -t chat-overlay:51-postgres-validation .`
y ejecutar `scripts/test_postgres_local.ps1` desde el worktree autorizado. El runner
comprueba ruta/rama, genera un proyecto Compose único, limita recursos, crea una
red/volumen aislados, no publica puertos y elimina solo los recursos de ese proyecto
en `finally`. Credenciales y datos son sintéticos. No monta socket Docker en tests.

`test_postgres/rls_test.exs` exige PostgreSQL real (sin skips ni exclusions); está
separado de la suite offline regular para que esta no necesite servicios. El runner
ejecuta la suite DB dos veces, luego `postgres_boot_smoke.exs`: producto completo,
Store real, mutación durable y reinicio desde PostgreSQL. Comprobar ambos reportes
con `scripts/check_test_report.py`; no sustituirlo por un conteo de declaraciones.
Los resultados concretos están en [registro local](workflows/postgres-rls/runs/2026-10-05.md).

No se han probado DB/TLS/restore de producción, pérdida de alimentación, plataformas
ni R2 reales, OBS, publicación o aislamiento ARCH-06. Issue #51 permanece abierta.
