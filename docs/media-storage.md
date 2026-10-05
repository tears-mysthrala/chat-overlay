# Inventario y cuota multimedia — #32 / #48

Las URLs PUT se entregan después de guardar una reserva en el documento de perfiles.
Cada clave nueva incluye el handle y un identificador aleatorio. La firma incluye
`content-length`, `content-type` y `host`; el cliente debe usar el MIME normalizado
que devuelve el endpoint. El permiso `can_upload` se comprueba en el servidor.

La asociación exige autorización de sesión, ticket AEAD temporal ligado a perfil,
clave, tamaño y categoría, URL CDN canónica, reserva vigente y metadatos HEAD de R2
coincidentes. El ticket no se persiste. La mutación vuelve a comprobar el inventario
bajo la serialización de `Profiles`, evitando reactivar un objeto retirado mientras
se realiza la validación HTTP.

## Contabilidad y limpieza

- `storage_used_bytes`: suma de objetos asociados actualmente a las alertas.
- `storage_pending_bytes`: reservas pendientes y objetos retirados que aún ocupan cuota.
- La cuota disponible descuenta ambos conceptos. Reemplazar una alerta libera su
  contador activo inmediatamente, pero el objeto anterior sigue cobrándose hasta
  confirmar DELETE y guardar el nuevo inventario.
- `media_objects`, en la raíz JSON, contiene el inventario acotado a 128 objetos,
  con un máximo de 12 por handle para preservar capacidad entre creadores.
  Se guarda atómicamente junto a los perfiles, con el límite global de 64 KiB.
- El proceso supervisado `MediaCleanup` intenta un objeto cada 30 segundos, en
  orden circular para no bloquear todos los objetos detrás de un fallo remoto.
  Solo intenta reservas vencidas u objetos retirados, transcurridos además 30 segundos
  desde el vencimiento del permiso PUT. Nunca elimina objetos activos.
- DELETE es idempotente: 200/204/404 permiten retirar la entrada; errores HTTP, red
  o disco conservan el inventario para reintentar. El borrado del perfil conserva
  sus objetos retirados hasta completar la limpieza. No se entregan permisos DELETE
  al navegador.
- La limpieza persiste el estado `deleting` bajo serialización, realiza DELETE fuera
  de `Profiles` y confirma el resultado mediante otra mutación serializada. Una caída
  conserva el claim para reintento; un objeto en limpieza no puede reactivarse.
- HEAD/DELETE usan exclusivamente el endpoint configurado por el operador, HTTPS
  443, resolución a IPv4 pública fijada para la conexión, TLS verificado y respuestas
  acotadas. No se siguen redirecciones. No hay credenciales ficticias por defecto
  fuera de la configuración de test.

## Límites y condiciones antes de activar subidas

**#49 / SEC-17 sigue pendiente.** HEAD verifica metadatos declarados, no el formato
real ni límites de decodificación. Una URL PUT puede reutilizarse durante su vigencia;
la espera de limpieza tampoco garantiza que una transferencia iniciada anteriormente
haya terminado. La publicación segura necesita cuarentena privada y promoción de un
artefacto validado e inmutable ligado a su hash. Este cambio no acredita ese requisito
ni autoriza activar subidas públicas. La validación se ha ejecutado con fixtures,
no contra una cuenta R2 real ni en OBS.

Los objetos heredados sin inventario no se eliminan a ciegas: nuevas reservas y el
borrado del perfil quedan bloqueados hasta conciliar propiedad, clave y tamaño.
La conciliación de datos existentes y la política de retención quedan en #48;
no se infiere propiedad únicamente de una URL externa. No se han modificado datos
reales ni ejecutado migraciones contra almacenamiento remoto.

La eliminación del perfil confirma eliminación local; los objetos permanecen en
el inventario hasta confirmación remota. Falta en #48 la vista operativa de borrados
pendientes, la reautenticación específica y la conciliación de inventario heredado.

## Configuración, compatibilidad y rollback

Se requieren `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` y
`R2_PUBLIC_CDN`; región predeterminada `auto`. Mantener secretos fuera de Git y logs.
El navegador necesita CORS para PUT y el Content-Type firmado; HEAD y DELETE los
realiza el servidor. No se ha cambiado configuración de buckets/CORS del operador.

El loader nuevo admite documentos antiguos sin `media_objects`. Una escritura nueva
incluye ese campo: **el loader anterior lo rechaza**. Antes de adoptar esta versión,
respaldar documento y clave según el procedimiento aprobado. Para rollback, detener
mutaciones y conservar el documento nuevo junto al backup: no borrar el inventario
ni restaurar una copia antigua sobre cambios posteriores. Conciliar objetos creados
tras el backup antes de volver a un binario anterior. El cambio se entrega para revisión,
sin merge, migración de datos de usuario ni despliegue.
