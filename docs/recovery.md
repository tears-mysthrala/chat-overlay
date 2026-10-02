# Recuperación y rotación offline — #40

Este procedimiento prepara artefactos locales; **no detiene servicios, cambia claves
reales, sustituye configuración ni despliega**. Ejecutarlo en producción necesita la
aprobación del operador y una ventana de mantenimiento. No pasar secretos como
argumentos ni pegar claves en issues, PR, historial de terminal o logs.

## Formato y custodia

La copia es JSON con `version: 1`, `key_id` (SHA-256 con separación de dominio de la
clave, identificador sin material secreto) y `payload` AEAD AES-256-GCM. El payload
cifra el documento completo, incluidos perfiles, permisos e inventario multimedia;
no solo los tokens. El AAD vincula versión e identificador de clave. Los tokens
internos mantienen el formato `v1:` y AAD `token:<handle>:<provider>`.

El fichero de clave contiene exactamente el valor de `CHAT_ENCRYPTION_KEY`, sin
salto de línea ni NUL, entre 32 y 4096 bytes; debe ser fichero regular, no symlink,
y no tener permisos de grupo/otros. Usar claves aleatorias de alta entropía y
custodiarlas separadamente de las copias. No almacenar copias ni claves en Git.
Las salidas tienen modo 0600 y no sustituyen destinos existentes, incluidos symlinks.
El staging es privado y la publicación usa enlace duro en el mismo filesystem;
si este no permite enlaces duros, falla sin recurrir a una copia insegura.

## Ensayo aislado

Desde el worktree correspondiente, con dependencias ya instaladas:

```sh
mix run --no-start scripts/recovery.exs backup /ruta/profiles.json /privado/clave-actual /privado/copia-v1.aead
mix run --no-start scripts/recovery.exs restore /privado/copia-v1.aead /privado/clave-actual /privado/restaurado.json
mix run --no-start scripts/recovery.exs rotate /privado/copia-v1.aead /privado/clave-actual /privado/clave-nueva /privado/copia-v2.aead
mix run --no-start scripts/recovery.exs restore /privado/copia-v2.aead /privado/clave-nueva /privado/rotado.json
```

`--no-start` evita arrancar aplicación, conectores, refrescos OAuth y limpieza R2.
Usar entorno offline sin variables de servicios reales. Estos comandos leen rutas;
ninguno recibe el valor de una clave en sus argumentos. La herramienta valida
configuración, inventario y descifrado de todas las credenciales antes de producir
una salida. Un registro antiguo `v1:` se vuelve a cifrar; uno corrupto, versión
no soportada o clave incorrecta aborta toda la operación. No se borra el original.
No mezclar claves de varias generaciones en el mismo documento.

## Cambio real, solo tras aprobación

1. Detener la instancia y todas las tareas que mutan perfiles, tokens u objetos.
   La herramienta no comprueba que otro proceso esté detenido. No crear el backup
   final mientras un worker pueda rotar un refresh token después de la copia.
2. Conservar imagen/binario aprobado y generar copia cifrada verificada con la
   clave anterior. Registrar `key_id`, fecha y versión del código en el inventario
   privado del operador, sin contenido de perfiles ni credenciales.
3. Preparar copia rotada y restauración a una ruta nueva. Comprobar con el loader
   y con credenciales sintéticas en un entorno aislado; no arrancar una copia de
   producción con conexiones externas para ensayar.
4. Configurar conjuntamente la ruta nueva y la nueva clave mediante el mecanismo
   de secretos aprobado; arrancar una única instancia. Comprobar readiness,
   autorización y acceso de los perfiles previstos sin imprimir tokens.
5. La nueva clave invalida cookies de sesión, OAuth pendiente y tickets de subida.
   Los usuarios vuelven a iniciar sesión/reintentan esos flujos. Los refresh tokens
   se conservan cifrados y los workers los cargan bajo la nueva clave al reiniciar.
6. Los capability tokens OBS son hashes independientes de la clave maestra:
   **siguen válidos**. Si la rotación responde a compromiso, regenerarlos mediante
   el flujo autorizado y actualizar OBS. Rotar la clave tampoco revoca credenciales
   comprometidas en Twitch/YouTube: reautenticar/revocar con el proveedor según incidente.

## Rollback y límites

Antes de arrancar con la nueva clave, se puede volver al par original documento/clave
conservado. Después de aceptar mutaciones nuevas o refrescos OAuth, **no restaurar
sin más la copia antigua**: puede resucitar permisos retirados, objetos borrados o
refresh tokens inválidos. Parar la instancia, conservar ambos estados, conciliar
inventario y revocar/reautenticar cuentas cuando proceda. Para revertir únicamente
la clave sin retroceder datos, respaldar el estado vigente y ejecutar la rotación
inversa offline a otro artefacto; si hubo compromiso, no reutilizar la clave expuesta.

La herramienta no exporta ni revoca secretos externos (R2/client secrets/túnel),
no copia los propios objetos R2 y no constituye almacenamiento con RLS (#51).
Conservar una clave antigua mientras existan copias que dependan de ella según
la política de retención aprobada; borrar una clave hace irrecuperables esas copias.
Un fsync del archivo y publicación atómica no acreditan durabilidad del directorio
ante pérdida de alimentación. Un staging residual tras terminación abrupta permanece
privado; verificar antes de retirarlo. Un destino existente nunca se sobrescribe.

## Evidencia

`mix test test/recovery_test.exs` usa dos perfiles y claves aleatorias sintéticas:
restauración de permisos, aislamiento AAD, cambio de clave, preservación de enlaces
OBS, invalidación criptográfica de sesiones, claves erróneas, corrupción/truncado,
versiones incompatibles, destino existente/symlink y fallo de ruta. El truncado
simula un artefacto incompleto, no un ensayo de corte eléctrico. No se han rotado
claves reales ni realizado recuperación de una instancia de producción.
