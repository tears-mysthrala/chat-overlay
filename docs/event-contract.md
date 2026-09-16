# Contrato de eventos F0

Este es el contrato de datos de referencia; F0 no implementa ingestión ni transporte.

## Envolvente

Cada evento futuro tendrá, como mínimo:

- `version`: versión entera del contrato.
- `event`: `message`, `delete_message`, `delete_author`, `clear_channel`, `replace`, `source_state`, `snapshot` o `reset`.
- `platform`: identificador cerrado de la plataforma, nunca texto ejecutable.
- `channel`: identificador estable del canal configurado.
- `emission_session`: sesión upstream cuando exista.
- `upstream_id`: identificador del evento de origen cuando exista.
- `received_at`: instante de recepción del servicio.
- `occurred_at`: instante de origen opcional y no usado como orden global.
- `local_sequence`: secuencia monotónica por overlay.
- `payload`: objeto tipado según `event`, sin tokens, cookies, continuaciones, campos internos ni cuerpo crudo.

`platform` solo puede ser `twitch`, `youtube` o `kick` en F1. El valor identifica
el adaptador, no demuestra titularidad ni autoriza acceso a una cuenta.

## Payloads normativos

Los siguientes esquemas son la definición F0 del payload lógico. Todos los IDs
son strings opacos no vacíos; los timestamps son ISO 8601 UTC; los campos no
indicados son rechazados o ignorados según la política de validación futura.

| Evento | Payload requerido | Semántica del recurso afectado |
| --- | --- | --- |
| `message` | `message_id`, `author_id`, `author_display`, `text` | Añade o reemplaza el mensaje identificado por `message_id`. `text` es texto Unicode, no HTML. |
| `delete_message` | `message_id`, `reason` opcional | Retira exactamente el mensaje `message_id`; no reutiliza el ID del evento. |
| `delete_author` | `author_id`, `reason` opcional | Retira los mensajes visibles cuyo autor estable sea `author_id` dentro de `channel`. |
| `clear_channel` | `scope` (`channel` o `source`), `reason` opcional | Vacía el estado visible del canal o de la fuente indicada por el sobre. |
| `replace` | `message_id`, `message` | Sustituye el mensaje `message_id` por el objeto `message` completo y tipado. |
| `source_state` | `state`, `detail` opcional, `observed_at` | Actualiza el estado de la fuente; `state` es `connecting`, `available`, `offline`, `degraded` o `configuration_error`. |
| `snapshot` | `messages`, `source_states`, `cursor`, `epoch` | Sustituye todo el estado visible del overlay; `messages` es una lista acotada y `cursor` puede ser nulo. |
| `reset` | `reason`, `epoch`, `snapshot_cursor` opcional | Invalida el cursor anterior y exige que el consumidor descarte el estado antes del snapshot siguiente. |

`reason`, `detail` y `scope` son datos tipados y acotados, nunca cuerpos crudos
de upstream. Un `delete_author` no afecta a autores con el mismo nombre visible
pero distinto `author_id`; un `clear_channel` no se interpreta como un borrado
individual. Los nombres de campos son parte del contrato y cualquier ampliación
requiere una nueva versión de `version` o una regla de compatibilidad explícita.

El identificador del evento no es el identificador del mensaje afectado. Un evento desconocido se ignora de forma limitada y no se registra su payload completo.

## Semántica

El orden es determinista dentro de un overlay. La deduplicación usa plataforma, canal, sesión e ID upstream cuando estén disponibles; nunca deduplica un borrado contra el mensaje que retira. `snapshot` sustituye el estado visible y `reset` indica que el cursor anterior ya no es recuperable. Los borrados no deben reaparecer por replay.

Los tamaños, historial, colas y frecuencia serán límites configurables con máximos globales definidos por REL-04/06. F1 añadirá pruebas de Unicode, duplicados, malformación, borrados y recuperación.
