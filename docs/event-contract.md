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

El identificador del evento no es el identificador del mensaje afectado. Un evento desconocido se ignora de forma limitada y no se registra su payload completo.

## Semántica

El orden es determinista dentro de un overlay. La deduplicación usa plataforma, canal, sesión e ID upstream cuando estén disponibles; nunca deduplica un borrado contra el mensaje que retira. `snapshot` sustituye el estado visible y `reset` indica que el cursor anterior ya no es recuperable. Los borrados no deben reaparecer por replay.

Los tamaños, historial, colas y frecuencia serán límites configurables con máximos globales definidos por REL-04/06. F1 añadirá pruebas de Unicode, duplicados, malformación, borrados y recuperación.
