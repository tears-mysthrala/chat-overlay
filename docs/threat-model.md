# Modelo de amenazas F1

Activos: tokens de lectura, disponibilidad, integridad del overlay y separación de perfiles. Entradas no confiables: visitantes HTTP, mensajes y errores upstream, DNS, callbacks y dependencias. La configuración del operador es una entrada privilegiada validada; nunca procede de una URL pública.

| Abuso | Control implementado y evidencia | Límite residual |
| --- | --- | --- |
| XSS desde chat | textContent, CSP, assets locales; caso literal HTML en demo y prueba DOM | CSP requiere prueba real en OBS |
| SSRF/red doméstica | hosts cerrados, IP pública fijada, TLS/hostname, sin redirects, sin URLs de usuario | DNS falla cerrado; solo IPv4 |
| Fuga entre perfiles | stores por handle, selección configurada, fuentes/autorización identificadas; tests A/B | F1 solo ofrece perfiles públicos |
| Robo de token | env en ejecución, cabeceras salientes, errores cerrados, format_status redactado | Administrador del host y volcados de VM pueden acceder; proteger el host |
| Callback falso/replay | RSA SHA-256 con clave oficial, timestamp ±300 s, IDs y dedup; pruebas de firma/tamper | Rotación de clave requiere actualización revisada; no conserva una cola durable |
| Saturación | límites de JSON, cuerpos, historial, replay, tombstones, SSE, conexiones, escritura y contenedor | Un atacante puede consumir las 100 plazas públicas o agotar el cupo de callbacks Kick con peticiones no autenticadas: proxy/segmentación por IP de egress de Kick antes de publicar |
| Resurrección tras borrado | barreras por mensaje/autor/canal, compactación, reset y limpieza tras huecos | Kick no proporciona borrado individual en la API usada |
| Caída de lector | tareas enlazadas, gracia, supervisión independiente; prueba de kill/reinicio | Corte completo del proceso pierde historial |
| Dependencia vulnerable | lock, digests, Hex audit, inventario, Grype con VEX fechado y auditado | Excepciones fechadas bajo revisión (revisión debida 2026-10-21): ver dependencies.md |
| Administración expuesta | rutas cerradas, sin ingestión general, métodos limitados | TLS/proxy y revisión de publicación pendientes |

No hay eval, átomos externos, shell de usuario, deserialización Erlang de datos de chat, HTML arbitrario, telemetría o llamadas a modelos. Los scripts de inventario procesan metadatos de build y no forman parte del servidor.

## Frontera de recuperación offline — #40

Activos: clave maestra, documento de perfiles, credenciales cifradas y copias.
Solo el operador autorizado ejecuta `scripts/recovery.exs`; las rutas, archivos y
artefactos importados requieren validación, aunque procedan de una copia local.
La herramienta se ejecuta con `--no-start`, sin conectores ni configuración real
de red. No establece una frontera contra un administrador del host comprometido.

| Abuso | Control | Riesgo residual |
| --- | --- | --- |
| Clave expuesta o ruta de clave no privada | Archivo regular sin symlink, permisos POSIX privados, tamaño acotado; claves fuera de argumentos/logs | lstat/read no es una apertura inmune a carreras: directorio y host deben ser confiables; Windows ACL no validada |
| Copia manipulada, truncada o con otra clave | AEAD, AAD de dominio/versión/key_id, límites y validación del documento y credenciales | El cifrado no impide restaurar una copia válida pero antigua |
| Destino existente o symlink | Staging privado y publicación por hard-link sin sobrescritura | Directorio padre debe ser confiable; fsync de archivo no acredita durabilidad del directorio |
| Restauración resucita permisos o refresh tokens | Parada previa de escritores, conciliación y reautenticación antes del cambio | La herramienta no comprueba parada ni revoca upstream; decisión del operador |
| Rotación incompleta o mezcla de generaciones | Verificación de todas las credenciales, salida nueva, cambio coordinado de documento/clave | Cookies y OAuth pendientes se invalidan; capabilities OBS y secretos externos necesitan revocación separada |

Las pruebas sintéticas de `recovery_test.exs` verifican errores, integridad y
publicación privada; no son un ensayo de recuperación de producción ni de corte
eléctrico. Conservar inventario multimedia al restaurar y custodiar las claves
separadas de las copias, con retención y eliminación autorizadas.
