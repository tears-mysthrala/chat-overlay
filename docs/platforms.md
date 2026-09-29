# Plataformas: preparación y límites de F1

Canal de referencia facilitado por Kalista: `gilraennr` en las tres plataformas. No hay aplicaciones/API registradas ni tokens disponibles; no se han validado IDs o lectura real. Esta guía no autoriza el registro de cuentas/apps, la publicación de un callback ni la transmisión de mensajes.

## Twitch

Registrar una aplicación propia en el portal de desarrolladores y obtener un **user access token** por el flujo oficial con `user:read:chat`. No se requiere un bot escritor. Resolver el ID numérico del broadcaster y del usuario autorizado con Helix; configurar `client_id`, `user_id`, `channel` y `credential_env`. El conector valida identidad y scope al arrancar y al menos cada hora activa, abre EventSub WebSocket y registra cuatro eventos de chat/borrado. Máximo tres fuentes WebSocket por pareja client_id/user_id; compartir una fuente entre perfiles evita duplicar conexiones.

La suscripción es una operación de control para recibir eventos, no envío de chat. La reconexión oficial conserva la sesión y drena mensajes pendientes; un corte que exige suscripción nueva vacía el historial local antes de reanudar. Tokens caducados/revocados muestran error de configuración; el operador los renueva fuera de esta app. No hay almacenamiento o refresh token automático en F1.

Los mensajes `channel.chat.message` pueden incluir `message.fragments` con emotes oficiales. El adaptador solo conserva `type`/`text`/`id` y descarta campos upstream (`emote_set_id`, `owner_id`, `format`). Recurso de terceros documentado y acotado (SEC-05): las imágenes se cargan desde `https://static-cdn.jtvnw.net` (CDN oficial de Twitch, solo `img-src`), construyendo la URL en el cliente a partir del `id` validado; sin ese `id` válido se muestra texto plano. Referencia: [EventSub channel.chat.message](https://dev.twitch.tv/docs/eventsub/eventsub-subscription-types/#channelchatmessage).

### Evaluación de interfaz GraphQL no documentada (ARCH-07)

Para satisfacer el requerimiento **ARCH-07** sobre interfaces no documentadas al descubrir enlaces a YouTube desde perfiles públicos de Twitch:

1. **Viabilidad técnica y necesidad**: La API oficial de Twitch (Helix) no expone los enlaces a redes sociales configurados por los streamers en su canal (`channel.socialMedias`). La interfaz GraphQL web pública de Twitch (`https://gql.twitch.tv/gql`) permite consultar bajo demanda `user.channel.socialMedias` para autodescubrir de forma fiable los enlaces a canales o transmisiones de YouTube configurados legítimamente por el streamer sin requerir credenciales adicionales ni recurrir a scraping frágil de HTML.
2. **Términos revisados**: Utiliza el endpoint público y el client ID web estándar (`kimne78kx3ncx6brgo4mv6wki5h1ko`). No evade mecanismos de autenticación privada, CAPTCHA, ni restricciones de acceso, ni emplea técnicas de evasión o rotación de IPs (ARCH-07).
3. **Tratamiento de texto como datos (AGENTS.md)**: La consulta utiliza variables GraphQL parametrizadas (`query($login: String)` / `query($id: ID)`) y nunca interpolación de cadenas de texto en el cuerpo de la query.
4. **Límites de uso y recursos**: Se ejecuta exclusivamente bajo demanda en la resolución o sincronización inicial de perfiles (`sync_youtube`), nunca en bucles de polling periódicos ni durante el streaming de mensajes. El tamaño de la respuesta está acotado por `Net.body_limit` (256 KiB) y timeout HTTP de 10 segundos.
5. **Mecanismo de desactivación**: Se proporciona la variable de entorno `CHAT_DISABLE_TWITCH_GQL=true` (o `1`) para desactivar de inmediato la consulta a GraphQL.
6. **Degradación visible**: Si la interfaz GraphQL está desactivada, devuelve error o resulta bloqueada por Twitch, el sistema degrada limpiamente e intenta extraer el enlace de la descripción o bio del canal (`user["description"]`) o recurre a la configuración manual del operador, reflejando el estado en los logs sin interrumpir la ejecución del servicio ni la visualización del overlay.
7. **Autorización**: Autorizado por el operador en el Issue #13 para la fase de pruebas y extensión local de resolución multistream en F1. Todo uso público o despliegue en producción requiere aprobación explícita de Kalista conforme a ARCH-07 y AGENTS.md.

## YouTube

Habilitar YouTube Data API para una aplicación propia. Se admiten dos mecanismos de autenticación mediante la variable de entorno configurada en `credential_env`:
1. **OAuth 2.0 Bearer token**: obtenido con scope `https://www.googleapis.com/auth/youtube.readonly` mediante el flujo oficial. Se envía mediante la cabecera `Authorization: Bearer <token>`.
2. **Google Cloud API Key**: clave de API con restricción de API limitada estrictamente a `youtube.googleapis.com` (prefijo estándar `AIza`) y restricción de aplicación compatible con el entorno de despliegue (p. ej. restricción por direcciones IP de salida del host donde corre el servicio; si el entorno no admite IP estática por tratarse de un despliegue con IP dinámica o local, el control alternativo es restringir la cuota diaria del proyecto y limitar estrictamente el acceso a solo YouTube Data API v3). Se detecta automáticamente y se envía mediante la cabecera HTTP `X-Goog-Api-Key: <key>`, permitiendo lectura de chats públicos sin flujos de consentimiento de usuario bloqueados y sin exponer credenciales en parámetros de consulta URL (SEC-06).

Configurar el ID estable del canal (`UC...`) y el `live_chat_id` de la emisión activa; un nombre público no sustituye ese ID. Las credenciales se envían siempre en cabeceras HTTP, nunca en la URL pública.

Para emisiones simultáneas o multiformato en un mismo canal (por ejemplo, directos paralelos horizontal 16:9 y vertical 9:16 como en emisiones 24/7 o simulcasts Shorts/escritorio), se configuran perfiles de operador independientes (p. ej. `directo-horizontal` y `directo-vertical`) con sus respectivos `live_chat_id`. El supervisor aísla los procesos de polling y los eventos en el store de cada perfil sin mezclar mensajes ni colisionar claves de supervisión.

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
