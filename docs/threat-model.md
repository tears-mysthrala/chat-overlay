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
