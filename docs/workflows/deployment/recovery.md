# Recuperación cifrada y mantenimiento local — Refs #40, #62

1. El operador conserva la clave RSA fuera de Drive en un directorio privado
   con ACL limitada. No perderla: sin ella el backup es irrecuperable. Mantener
   una segunda custodia independiente antes de considerar completa la continuidad.
   Benten recibe únicamente el certificado público.
2. Ejecutar `sh deploy/benten/backup.sh /ruta/certificado-publico.pem` solo en
   VM9502 verificada, con app y coordinador activos. El script detiene ambos,
   toma dump/roles y estado de medios/configuración, cifra CMS AES-256-GCM y
   reanuda servicios con trap. Copiar exclusivamente backup.cms al destino.
3. Comparar SHA256 en Benten, destino local y descarga remota independiente.
   Verificar que Drive contiene el archivo y no está compartido. El conector
   puede devolver un materializador403: no confundir presencia remota con una
   prueba de lectura independiente. Registrar ese límite y conservar la copia.
4. Descifrar a un directorio privado local con `openssl cms -decrypt -binary
   -inform DER -inkey <clave-local> -in <backup.cms> -out <bundle.tar>`. Exigir
   exit0 antes de extraer o usar cualquier salida; OpenSSL puede dejar salida
   parcial cuando falla la autenticación. No enviar bundle ni clave a Drive.
5. `python scripts/check_backup_restore.py <bundle-autenticado> <directorio-privado-nuevo>`
   valida miembros/checksums, SQLite y medios, restaura PostgreSQL sin red y
   comprueba conteos/FORCE RLS y descifrado en la imagen real sin upstream.
   Los archivos extraídos contienen secretos: permanecer en el directorio privado.
   El checker elimina solo su contenedor aleatorio, nunca servicios reales.
6. La recuperación efectiva sobre producción exige parar writers, conservar
   cambios posteriores al backup y decidir cómo conciliarlos. Esta prueba no
   autoriza restaurar una copia vieja sobre datos activos ni rotar claves reales.

## Compactación local

Después de un backup verificado, detener app y coordinador y drenar cualquier
decoder (límite de ejecución10s). Exportar los objetos de PostgreSQL a JSON en
directorio privado. No admitir writers concurrentes. Ejecutar
`python scripts/compact_local_media.py <root-local> <ledger-json> --writers-stopped`.
La bandera es una afirmación del operador, no detiene servicios por sí sola.
Abortar ante estados pendientes o ambiguos; no manipular el ledger para forzar
aceptación. El script conserva todos los bytes activos y retira solo historial
resuelto/tombstones sin archivos. Reanudar servicios con trap y comprobar cuotas,
lectura de medios, readiness y logs sin secretos. No usar para backend R2.

La copia real y la compactación son operaciones manuales en esta unidad. No hay
temporizador de backup, política de borrado automático ni garantía comercial.
