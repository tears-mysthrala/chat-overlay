# Modelo de amenazas F1/F2

Activos: tokens de lectura, disponibilidad, integridad del overlay y separación de perfiles. Entradas no confiables: visitantes HTTP, mensajes y errores upstream, DNS, callbacks y dependencias. La configuración del operador es una entrada privilegiada validada; nunca procede de una URL pública.

| Abuso | Control implementado y evidencia | Límite residual |
| --- | --- | --- |
| XSS desde chat | textContent, CSP, assets locales; caso literal HTML en demo y prueba DOM | CSP requiere prueba real en OBS |
| SSRF/red doméstica | hosts cerrados, IP pública fijada, TLS/hostname, sin redirects, HEAD/DELETE multimedia solo al endpoint del operador | DNS falla cerrado; solo IPv4 |
| Fuga entre perfiles | stores por handle, selección configurada, fuentes/autorización identificadas; tests A/B | Sesiones comprueban perfil/identidad/versión; JSON no acredita RLS (#51) |
| Robo de token | env en ejecución, cabeceras salientes, errores cerrados, format_status redactado | Administrador del host y volcados de VM pueden acceder; proteger el host |
| Callback falso/replay | RSA SHA-256 con clave oficial, timestamp ±300 s, IDs y dedup; pruebas de firma/tamper | Rotación de clave requiere actualización revisada; no conserva una cola durable |
| Saturación | límites de JSON, cuerpos, historial, replay, tombstones, SSE, conexiones, escritura y contenedor | Un atacante puede consumir las 100 plazas públicas o agotar el cupo de callbacks Kick con peticiones no autenticadas: proxy/segmentación por IP de egress de Kick antes de publicar |
| Resurrección tras borrado | barreras por mensaje/autor/canal, compactación, reset y limpieza tras huecos | Kick no proporciona borrado individual en la API usada |
| Caída de lector | tareas enlazadas, gracia, supervisión independiente; prueba de kill/reinicio | Corte completo del proceso pierde historial |
| Dependencia vulnerable | lock, digests, Hex audit, inventario, Grype con VEX fechado y auditado | Excepciones fechadas bajo revisión (revisión debida 2026-10-21): ver dependencies.md |
| Administración expuesta | sesión y autorización por perfil, métodos limitados, excepción demo local | TLS/proxy y revisión de publicación pendientes |

No hay eval, átomos externos, shell de usuario, deserialización Erlang de datos de chat, HTML arbitrario, telemetría o llamadas a modelos. Los scripts de inventario procesan metadatos de build y no forman parte del servidor.

## Superficies F2 y deuda (2026-10-02)

| Abuso | Evidencia candidata | Pendiente / límite |
| --- | --- | --- |
| Cookie de otro perfil o posterior a unlink/relink | `session_test.exs`, `web_session_auth_test.exs`, `tokens_test.exs` y gates de ciclo de vida | No acredita aislamiento de filas en almacenamiento (#51) |
| Callback OAuth sin flujo ligado o identidad equivocada | `oauth_test.exs`, pruebas web de sesión/OAuth | Revalidar E2E y proveedor real por separado (#43/#44) |
| Carrera entre refresh, unlink y persistencia | `token_lifecycle_gate_test.exs`, `profile_persistence_test.exs` | JSON, memoria y workers no constituyen una transacción distribuida |
| Reservas concurrentes o borrado R2 fallido | `media_ledger_test.exs`, `web_f2_test.exs`; PR #57 | Inventario heredado pendiente de conciliación (#48) |
| Archivo con MIME falso, decoder hostil o PUT reutilizado | Metadatos firmados/HEAD solo acotan la petición | Cuarentena, bytes reales y salida inmutable **pendientes** (#49) |
| Copia o rotación de clave incompleta | `recovery_test.exs`, copia AEAD y destinos nuevos | Ensayo sintético offline; no corte eléctrico ni recuperación real |
| Proceso público comprometido lee todos los secretos | Ninguna afirmación de aislamiento suficiente | ARCH-06/#39 y SEC-13 bloquean publicación |

Las URLs externas se cargan en el navegador; la comprobación DNS al guardarlas no
es pinning de futuras peticiones del navegador ni inspección del archivo. Su uso
requiere origen confiable y política CSP; no se declara eliminada toda SSRF/XSS por
validar una extensión. No se publican aquí reproducciones sensibles (DEV-09).
## Transacciones OAuth — #42

El callback HTTP exige el estado cifrado y la cookie HttpOnly del navegador que
inició el flujo. El registro privado de hashes consume la pareja de forma atómica,
antes del intercambio remoto, también ante denegación del proveedor o fallo.
La cookie usa SameSite=Lax para el retorno GET y Secure cuando el transporte
usa TLS directo o procede de una IP de proxy explícitamente configurada en
`CHAT_TRUSTED_PROXY_IPS` con una única cabecera `X-Forwarded-Proto: https`.
Sin proxy configurado no se confía en esa cabecera. El operador debe impedir
acceso directo y hacer que el proxy reemplace las cabeceras del cliente; esta
frontera sigue pendiente de validación en la infraestructura real. Fuera de
loopback no se inicia un flujo sobre HTTP no confiable.

El registro admite 1024 transacciones, hasta 512 anónimas, cuatro anónimas por
perfil y solicitante y ocho autorizadas por perfil, con vida de diez minutos y
limpieza al acceder. Conserva hashes e instantáneas de identidad/autorización;
un reinicio cancela los flujos pendientes. Cada transacción tiene una cookie
independiente que se borra al consumirla; HTTPS usa el prefijo `__Host-`.
La escritura revalida la sesión y la instantánea dentro del escritor serializado.
NAT y peers de proxy sin XFF único verificado comparten la cuota anónima.
Ver [configuración y límites](oauth-runtime.md).
No se acredita coordinación entre réplicas, navegador/proveedor real, ni se
sustituye la autorización vigente del perfil por el binding del navegador.

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
