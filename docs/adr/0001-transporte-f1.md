# ADR 0001 — Transporte F1 y herramientas

Estado: aceptada por Kalista el 20-09-2026 para issue #3. Sustituir Cowboy/Gun por Bandit + Mint/Mint.WebSocket fue autorizado expresamente. Se mantiene Elixir/OTP, frontend estático y Docker, sin Phoenix ni base de datos.

## Motivo y alternativas

La auditoría con Hex 2.5.1 del árbol Cowboy/Gun encontró tres avisos sin resolver. El árbol aprobado utiliza Bandit/Plug/Thousand Island para HTTP y Mint para conexiones salientes; Mint.WebSocket mantiene el protocolo, masking y fragmentación en una biblioteca, sin implementación criptográfica propia. Se aceptan diez dependencias transitivas/directas pequeñas a cambio de retirar Cowlib y los avisos detectados. Fijar versiones no elimina el seguimiento de seguridad.

Twitch usa EventSub WebSocket oficial y API de suscripciones, no IRC anónimo o endpoints internos. YouTube usa `liveChatMessages.list`, respetando continuación y `pollingIntervalMillis`; `streamList` oficial es una futura alternativa si las mediciones justifican gRPC y sus dependencias. Kick usa callbacks oficiales firmados y consulta de suscripciones: el proveedor requiere un endpoint HTTPS accesible, por lo que el vivo no puede demostrarse solo con localhost.

Frontend propio sin framework, texto con DOM seguro y SSE nativo; evita pipeline Node en producción. JSON procede de Elixir 1.20.4. Sin almacenamiento durable ni OAuth interactivo: los tokens de lectura los provisiona el operador, con permisos mínimos.

Herramientas: ExUnit para contratos/protocolos y aislamiento, Chromium para DOM, Docker para límites y release, Hex audit para avisos Hex, Syft para imagen, inventario suplementario para paquetes BEAM (Syft no los detectó), Grype para CVE de imagen, Gitleaks para secretos y reglas estáticas pequeñas contra prohibiciones del contrato. Ninguna herramienta equivale a una auditoría completa. El SBOM se conserva incluso con hallazgos; no hay allowlist de CVE.

Alpine sustituye la prueba inicial Debian Bookworm: esta presentó 232 coincidencias de Grype; Alpine reduce superficie pero conserva cuatro hallazgos conocidos. No se mantiene una distribución propia para eliminarlos del informe. Se bloquea publicación hasta corrección o resolución humana documentada.

## Fuentes

- [Bandit](https://bandit.hexdocs.pm/Bandit.html), [Mint](https://mint.hexdocs.pm/Mint.HTTP.html), [Mint.WebSocket](https://mint-web-socket.hexdocs.pm/Mint.WebSocket.html).
- [Twitch EventSub](https://dev.twitch.tv/docs/eventsub/handling-websocket-events/) y [validación de tokens](https://dev.twitch.tv/docs/authentication/validate-tokens/).
- [YouTube list](https://developers.google.com/youtube/v3/live/docs/liveChatMessages/list), [streamList](https://developers.google.com/youtube/v3/live/streaming-live-chat).
- [Kick seguridad](https://github.com/KickEngineering/KickDevDocs/blob/main/events/webhook-security.md) y [eventos](https://github.com/KickEngineering/KickDevDocs/blob/main/events/event-types.md).
