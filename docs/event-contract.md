# Contrato de eventos implementado — versión 1

`Event` valida sobres cerrados: `version`, `event`, `platform`, `channel`, `emission_session` opcional, `upstream_id`, `received_at`, `occurred_at` opcional y `payload`. IDs: UTF-8 no vacío, máximo 256 bytes; autor visible: 256 bytes; mensaje: 4096 bytes; timestamps: ISO 8601 UTC. No se conservan campos crudos, credenciales o continuaciones.

| Evento | Payload exacto |
| --- | --- |
| message | message_id, author_id, author_display, text, fragments (optional) |
| delete_message | message_id |
| delete_author | author_id |
| clear_channel | scope: channel |
| replace | message_id, message (payload completo) |
| source_state | state, observed_at |
| snapshot (interno) | messages, source_states, cursor, epoch |
| reset (interno) | reason, epoch |

Plataformas: twitch, youtube, kick. Estados: connecting, available, offline, degraded, configuration_error. Las ampliaciones requieren revisión del esquema; los adaptadores ignoran eventos desconocidos, pero rechazan mensajes conocidos malformados.

El almacén ordena por secuencia local. La clave de deduplicación combina fuente, sesión, tipo e ID de evento. La identidad de mensaje usa fuente, sesión e ID de mensaje. Los borrados de autor usan ID estable, nunca nombre visible. Las barreras de canal/autor no retroceden al llegar eventos fuera de orden; mensajes sin fecha se rechazan conservadoramente tras un borrado. Las barreras individuales duran 30 minutos. Su capacidad máxima es 4096; la saturación vacía el perfil y cambia época. Una reconexión upstream vacía el contenido antiguo porque no se puede demostrar que no haya sido borrado durante el corte.

SSE emite `event: batch`, `id: <epoch>:<sequence>` y JSON con `events`. El cliente aplica el lote antes de pintar. `Last-Event-ID` recupera los últimos 512 eventos o provoca `reset` seguido de `snapshot`. Caducar mensajes o entradas de replay invalida el replay previo. Un borrado purga el replay para no conservar el texto retirado; las expulsiones por capacidad emiten una retirada incluso a visores filtrados. No existe orden global entre plataformas ni entrega exactamente una vez.

`overlay_platforms` filtra mensajes y estados en snapshots y deltas para la vista de emisión. El lector conserva las fuentes configuradas. Ambos siguen siendo públicos.

### Fragmentos de mensaje (extensión retrocompatible)

El payload de `message` puede incluir opcionalmente `fragments`: una lista ordenada de fragmentos que compone el texto del mensaje. Cuando no está presente, el cliente renderiza `text` como texto plano. Cada fragmento es un mapa cerrado de uno de los tipos:

| Tipo | Campos | Descripción |
| --- | --- | --- |
| text | type, text | Texto plano (hasta 4096 bytes UTF-8). |
| emote | type, text, id | Emote oficial; `id` es alfanumérico con `_-:` (hasta 256 bytes), `text` es el nombre visible (hasta 256 bytes). |

Restricciones: máximo 100 fragmentos por mensaje; campos extra rechazan el evento; IDs con caracteres fuera del patrón `[a-zA-Z0-9_\-:]` se rechazan. El campo `text` del sobre mantiene siempre la representación completa en texto plano para accesibilidad y búsqueda.

Las URLs de imagen de emotes se construyen en el cliente a partir del `id` y la plataforma. CSP permite `https://static-cdn.jtvnw.net` (Twitch) como origen de imagen documentado y acotado conforme a SEC-05.
