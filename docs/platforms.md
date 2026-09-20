# Plataformas: preparación y límites de F1

Canal de referencia facilitado por Kalista: `gilraennr` en las tres plataformas. No hay aplicaciones/API registradas ni tokens disponibles; no se han validado IDs o lectura real. Esta guía no autoriza el registro de cuentas/apps, la publicación de un callback ni la transmisión de mensajes.

## Twitch

Registrar una aplicación propia en el portal de desarrolladores y obtener un **user access token** por el flujo oficial con `user:read:chat`. No se requiere un bot escritor. Resolver el ID numérico del broadcaster y del usuario autorizado con Helix; configurar `client_id`, `user_id`, `channel` y `credential_env`. El conector valida identidad y scope al arrancar y al menos cada hora activa, abre EventSub WebSocket y registra cuatro eventos de chat/borrado. Máximo tres fuentes WebSocket por pareja client_id/user_id; compartir una fuente entre perfiles evita duplicar conexiones.

La suscripción es una operación de control para recibir eventos, no envío de chat. La reconexión oficial conserva la sesión y drena mensajes pendientes; un corte que exige suscripción nueva vacía el historial local antes de reanudar. Tokens caducados/revocados muestran error de configuración; el operador los renueva fuera de esta app. No hay almacenamiento o refresh token automático en F1.

## YouTube

Habilitar YouTube Data API para una aplicación propia y obtener autorización de solo lectura (`https://www.googleapis.com/auth/youtube.readonly`) mediante el flujo oficial. Configurar el ID estable del canal y el `live_chat_id` de la emisión activa; un nombre público no sustituye ese ID. El token se pasa como Authorization, nunca en la URL pública.

Se consulta `liveChatMessages.list` con 200 resultados máximos, continuación y espera al menos igual a `pollingIntervalMillis`. La primera consulta puede devolver historial reciente; tras un hueco se descartan mensajes anteriores a la barrera local para evitar resurrecciones. Se distinguen directo terminado, autorización y cuota. `Retry-After` es una espera mínima; los reintentos tienen jitter y backoff. El fin de una emisión requiere actualizar su live_chat_id. Las cuotas y latencia real siguen pendientes de medición.

## Kick

La API oficial utiliza webhooks: requiere aplicación, token con acceso a suscripciones (`events:subscribe` según la documentación vigente), broadcaster ID numérico y endpoint HTTPS publicado. El operador debe aprovisionar suscripciones para `chat.message.sent` y, si procede, `moderation.banned`, guardando sus IDs como `subscription_id` y `moderation_subscription_id`. No hay acceso mediante cookies ni endpoints internos.

Ruta receptora: `/hooks/kick`. Verifica RSA SHA-256 sobre id.timestamp.cuerpo con clave pública oficial, frescura de cinco minutos y correspondencia de canal, evento y suscripción. No se conserva contenido sin lectores. La consulta de suscripciones no demuestra frescura de entrega: muestra degradado hasta recibir un callback válido. No existe en los eventos oficiales utilizados un borrado individual equivalente al de Twitch/YouTube; no se promete esa cobertura. Confirmar comportamiento y condiciones del proveedor antes del vivo.

## JSON del operador

Ejemplo estructural, **no listo para conectar**. Sustituir IDs antes de usarlo. Guardarlo como `config/local-profiles.json` (ignorado por Git). Inyectar las variables secretas en el entorno del proceso mediante el gestor del operador, sin escribir valores en este archivo.

```json
{"profiles":[{"handle":"gilraennr","overlay_platforms":["twitch"],"sources":[
  {"platform":"twitch","channel":"123456","client_id":"REEMPLAZAR_CLIENT_ID","user_id":"123456","credential_env":"CHAT_TWITCH_TOKEN"},
  {"platform":"youtube","channel":"REEMPLAZAR_CHANNEL_ID","live_chat_id":"REEMPLAZAR_LIVE_CHAT_ID","credential_env":"CHAT_YOUTUBE_TOKEN"},
  {"platform":"kick","channel":"123456","subscription_id":"REEMPLAZAR_SUBSCRIPTION_ID","credential_env":"CHAT_KICK_TOKEN"}
]}]}
```

Los permisos dependen del flujo y contrato vigentes. Comprobar titularidad, scopes, condiciones de API/visualización y simulcasting en los portales oficiales al registrar. `overlay_platforms` permite reducir qué chats salen en la imagen emitida; el lector también es público y no ofrece una excepción a las políticas.

## Validación en vivo pendiente

Por plataforma: identidad/ID, lectura Unicode, offline, token inválido/caducado, cuota, reconexión, duplicados y eventos de borrado soportados. Registrar fecha, servidor y versiones sin tokens ni datos personales. El producto no envía mensajes para generar la prueba. Después: OBS real, CSP/transparencia, cierre/reapertura de fuente de navegador y pérdida/reanudación SSE.

Fuentes: [Twitch permisos](https://dev.twitch.tv/docs/chat/authenticating/), [Twitch WebSocket](https://dev.twitch.tv/docs/eventsub/handling-websocket-events/), [YouTube list](https://developers.google.com/youtube/v3/live/docs/liveChatMessages/list), [Kick documentación oficial](https://github.com/KickEngineering/KickDevDocs).

Las respuestas de YouTube tienen un presupuesto de 2 MiB para páginas de 200 recursos y selección explícita de campos; el resto de respuestas/frames se limita a 256 KiB. El handshake WebSocket rechaza respuestas distintas de 101 y acota el contenido recibido. Las esperas upstream sobreviven a cerrar y reabrir visores.
