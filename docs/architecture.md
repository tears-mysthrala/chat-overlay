# Arquitectura F1/F2 y límites vigentes

```text
Configuración del operador -> Config (validación cerrada)
                                   |
Registro OTP <- Store por perfil <- Source por fuente/autorización
                   |                | Task cancelable + Mint TLS/WebSocket
                   |                | Twitch EventSub / YouTube API
                   |                + Kick API: estado de suscripciones
                   + <- firma RSA <- POST /hooks/kick
                   |
                  SSE <- Admission (100 lectores) <- Bandit / Plug
                   |
             lector y overlay: assets propios + textContent
```

El supervisor raíz usa `rest_for_one` para reconstruir dependencias de infraestructura; los supervisores de stores y fuentes usan `one_for_one`. Una fuente que cae no reinicia otra. Cada tarea está enlazada a su propietario y se cancela al perder demanda. Una fuente se comparte solo cuando plataforma, canal y contexto de credencial coinciden y su configuración es idéntica.

La primera vista activa la fuente; la última inicia una gracia de 60 segundos. El cierre TCP de un visor puede detectarse en la siguiente escritura/heartbeat (hasta 15 segundos adicionales). Admission libera explícitamente la reserva al finalizar SSE y monitoriza caídas. Los conectores no siguen leyendo indefinidamente sin lectores. Kick requiere suscripciones previamente aprovisionadas: sin demanda se verifican y descartan sus callbacks, sin conservar contenido.

Store tiene un único escritor, historial de 100 mensajes/30 minutos, replay de 512 eventos con caducidad y purga al borrar, deduplicación de 4096 claves y hasta 4096 barreras de borrado. Una inundación de borrados compacta todas las barreras del perfil, vacía el contenido y fuerza reset/degradado. Ninguna cola de mensajes por visor acumula el flujo: SSE consulta cambios cada 50 ms y escribe de forma síncrona. Un cursor caducado recibe snapshot; una escritura bloqueada tiene timeout de 5 segundos.

Límites de red: 4 aceptores con 128 conexiones máximas cada uno, 100 SSE globales, HTTP/2 desactivado, 30 cabeceras de 2048 bytes y línea de 2048 bytes, lectura HTTP 5 segundos. Los callbacks admiten 64 KiB y 250 solicitudes/s agregadas; TLS saliente usa destinos cerrados, DNS IPv4 público fijado a la conexión y verificación del hostname original. No se siguen redirecciones. Se rechaza IPv6 saliente para no introducir una segunda política incompleta.

Existe API de administración F2 de perfiles, sesiones, cuentas, tokens y multimedia; requiere autorización de perfil salvo el modo demo local delimitado. No hay ingestión general de chat. `/hooks/kick` es exclusivamente la recepción autenticada del proveedor, con firma del cuerpo, frescura, suscripción y canal configurados. No se confía en cabeceras de proxy para identidad o cuota. La separación privada se comprueba en `Session.authorize`; el backend JSON compartido no acredita RLS (SEC-13, #51).

HTTP público termina TLS en el proxy del operador, aún no desplegado. El servicio y sus assets comparten origen. No hay Phoenix, DB, caché externa ni procesos shell durante el procesamiento de chats.

Las respuestas de YouTube tienen un presupuesto de 2 MiB para páginas de 200 recursos y selección explícita de campos; el resto de respuestas/frames se limita a 256 KiB. El handshake WebSocket rechaza respuestas distintas de 101 y acota el contenido recibido. Las esperas upstream sobreviven a cerrar y reabrir visores.

## Control F2

`Profiles` serializa mutaciones y persiste antes de confirmar cambios de runtime.
`Session` cifra cookies, comprueba identidad/versión de cuenta y limita acceso por
perfil. `OAuth` liga callback al flujo autorizado; `Tokens` coordina refresh con
versiones y cancelación ante unlink/relink. Los conectores de lectura conservan su
configuración de operador; integración de cuentas dinámicas para bot está en #47/F3.

Las capabilities OBS se guardan como hashes y se regeneran con desconexión SSE.
El cierre de lectores, revocación y eliminación tienen pruebas negativas; los
resultados históricos de OBS no prueban automáticamente esta candidata.

En la candidata #57, `media_objects` persiste reservas/activos/retirados junto a los
perfiles. El navegador sube directo a R2; HEAD/DELETE son peticiones de control del
servidor, con destino del operador y TLS fijado. `MediaCleanup` reintenta limpieza;
[detalles y límites](media-storage.md). Extensión/MIME/HEAD no validan formato real.

[Recuperación offline](recovery.md) prepara artefactos cifrados sin arrancar workers.
Las propuestas [SEC-13/SEC-17](adr/0005-f2-isolation-and-quarantine-proposal.md) están
pendientes de aprobación y no describen servicios ya implementados. ARCH-06/#39
mantiene separación efectiva de secretos/proceso como gate de publicación.
