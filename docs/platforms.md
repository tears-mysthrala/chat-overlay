# Plataformas: preparación y límites de F1

Canal de referencia facilitado por Kalista: `gilraennr` en las tres plataformas. El cierre histórico #21 recoge lectura real de Twitch/YouTube; esta revisión no inspecciona credenciales ni repite conexiones reales. El estado actual debe verificarse por separado (#44). Esta guía no autoriza el registro de cuentas/apps, la publicación de un callback ni la transmisión de mensajes.

## Twitch

Registrar una aplicación propia en el portal de desarrolladores y obtener un **user access token** por el flujo oficial con `user:read:chat`. No se requiere un bot escritor. Resolver el ID numérico del broadcaster y del usuario autorizado con Helix; configurar `client_id`, `user_id`, `channel` y `credential_env`. El conector valida identidad y scope al arrancar y al menos cada hora activa, abre EventSub WebSocket y registra cuatro eventos de chat/borrado. Máximo tres fuentes WebSocket por pareja client_id/user_id; compartir una fuente entre perfiles evita duplicar conexiones.

La suscripción es una operación de control para recibir eventos, no envío de chat. La reconexión oficial conserva la sesión y drena mensajes pendientes; un corte que exige suscripción nueva vacía el historial local antes de reanudar. Los conectores de lectura mantienen credenciales de operador. F2 añade almacenamiento cifrado y refresh de cuentas vinculadas; integrarlo con futuros conectores/bot está en #47 y requiere aprobación F3. No confundir ambos caminos.

Los mensajes `channel.chat.message` pueden incluir `message.fragments` con emotes oficiales. El adaptador solo conserva `type`/`text`/`id` y descarta campos upstream (`emote_set_id`, `owner_id`, `format`). Recurso de terceros documentado y acotado (SEC-05): las imágenes se cargan desde `https://static-cdn.jtvnw.net` (CDN oficial de Twitch, solo `img-src`), construyendo la URL en el cliente a partir del `id` validado; sin ese `id` válido se muestra texto plano. Referencia: [EventSub channel.chat.message](https://dev.twitch.tv/docs/eventsub/eventsub-subscription-types/#channelchatmessage).

### Evaluación de interfaz GraphQL no documentada (ARCH-07)

Para satisfacer el requerimiento **ARCH-07** sobre interfaces no documentadas al descubrir enlaces a YouTube desde perfiles públicos de Twitch:

1. **Viabilidad técnica y necesidad**: La API oficial de Twitch (Helix) no expone los enlaces a redes sociales configurados por los streamers en su canal (`channel.socialMedias`). La interfaz GraphQL web pública de Twitch (`https://gql.twitch.tv/gql`) permite consultar bajo demanda `user.channel.socialMedias` para autodescubrir de forma fiable los enlaces a canales o transmisiones de YouTube configurados legítimamente por el streamer sin requerir credenciales adicionales ni recurrir a scraping frágil de HTML.
2. **Límite de la evaluación técnica (términos pendientes de revisión vigente en #45)**: Utiliza el endpoint público y el client ID web estándar (`kimne78kx3ncx6brgo4mv6wki5h1ko`). No evade mecanismos de autenticación privada, CAPTCHA, ni restricciones de acceso, ni emplea técnicas de evasión o rotación de IPs (ARCH-07).
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

**Estado de integración en F1: DIFERIDO / SUSPENDIDO por decisión del operador (issue #15).**

Motivación técnica y gobernanza:
1. **Inestabilidad crítica de API upstream**: Durante el último año, la API de desarrolladores de Kick ha sufrido entre 4 y 5 modificaciones estructurales y de versionado (cambios incompatibles / breaking changes continuos entre v1 y v2), forzando a reconstruir periódicamente los clientes y aplicaciones de integración.
2. **Fricción operativa y deuda técnica**: El modelo de suscripción mediante webhooks (`events:subscribe`) exige registro de aplicaciones en su portal de desarrolladores, validación de endpoints HTTPS con firma RSA y rotación recurrente de credenciales. La ausencia de garantías contractuales de estabilidad en los payloads genera un coste desproporcionado de mantenimiento para el proyecto en su fase inicial.
3. **Decisión**: Para evitar acumular deuda técnica recurrente en componentes inestables, el operador Kalista ha dispuesto suspender y abandonar temporalmente el soporte de Kick en F1, concentrando el alcance de producción en la dualidad Twitch + YouTube (altamente estables y validados en directo). Si en fases futuras Kick consolida una API madura y con garantías de compatibilidad, se reevaluará su reincorporación mediante un ADR específico.
4. **Referencia técnica archivada**: La especificación inicial contemplaba webhooks en `/hooks/kick` con firma RSA SHA-256 sobre `id.timestamp.cuerpo` y verificación de frescura de 5 minutos, con las limitaciones conocidas de no ofrecer borrado individual de mensajes. Esta implementación queda en reposo sin activación operativa.

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
