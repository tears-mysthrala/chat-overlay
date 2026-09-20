# Modelo de amenazas F1

Activos: tokens de lectura, disponibilidad, integridad del overlay y separación de perfiles. Entradas no confiables: visitantes HTTP, mensajes y errores upstream, DNS, callbacks y dependencias. La configuración del operador es una entrada privilegiada validada; nunca procede de una URL pública.

| Abuso | Control implementado y evidencia | Límite residual |
| --- | --- | --- |
| XSS desde chat | textContent, CSP, assets locales; caso literal HTML en demo y prueba DOM | CSP requiere prueba real en OBS |
| SSRF/red doméstica | hosts cerrados, IP pública fijada, TLS/hostname, sin redirects, sin URLs de usuario | DNS falla cerrado; solo IPv4 |
| Fuga entre perfiles | stores por handle, selección configurada, fuentes/autorización identificadas; tests A/B | F1 solo ofrece perfiles públicos |
| Robo de token | env en ejecución, cabeceras salientes, errores cerrados, format_status redactado | Administrador del host y volcados de VM pueden acceder; proteger el host |
| Callback falso/replay | RSA SHA-256 con clave oficial, timestamp ±300 s, IDs y dedup; pruebas de firma/tamper | Rotación de clave requiere actualización revisada; no conserva una cola durable |
| Saturación | límites de JSON, cuerpos, historial, replay, tombstones, SSE, conexiones, escritura y contenedor | Un atacante puede consumir las 100 plazas públicas: proxy/segmentación antes de publicar |
| Resurrección tras borrado | barreras por mensaje/autor/canal, compactación, reset y limpieza tras huecos | Kick no proporciona borrado individual en la API usada |
| Caída de lector | tareas enlazadas, gracia, supervisión independiente; prueba de kill/reinicio | Corte completo del proceso pierde historial |
| Dependencia vulnerable | lock, digests, Hex audit, inventario, Grype sin supresiones | Hallazgos de imagen pendientes: ver dependencies.md |
| Administración expuesta | rutas cerradas, sin ingestión general, métodos limitados | TLS/proxy y revisión de publicación pendientes |

No hay eval, átomos externos, shell de usuario, deserialización Erlang de datos de chat, HTML arbitrario, telemetría o llamadas a modelos. Los scripts de inventario procesan metadatos de build y no forman parte del servidor.
