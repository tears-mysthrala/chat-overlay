# Protocolo privado v1 — Refs #39

Estado: transporte y handlers implementados en la candidata; validación en curso.
No está habilitado en Benten. Aprobación de ADR0008: Kalista, 07-10-2026.

El canal interno usa TLS mutuo y una CA dedicada. No hay distribución Erlang,
deserialización de términos ni URL de destino elegida por el visitante. Los
certificados identifican procesos; no sustituyen permisos de sesión/perfil.
El único receptor es el custodio configurado por el operador.

Cada solicitud JSON contiene exactamente `version`, `operation`, `arguments`.
Versión entera 1; operación de la lista cerrada; claves de argumentos binarias.
Se rechazan campos desconocidos, tipos inválidos, documentos de profundidad
superior a ocho, listas de más de 128 elementos y mensajes superiores a 65536
bytes. Sesión y capability son credenciales opacas, nunca pruebas booleanas de
autorización. `origin` y `requester` son contexto observado por el frente;
un frente comprometido puede falsificarlos. El custodio no deriva permisos de
ellos y debe imponer cuotas agregadas independientes de la IP declarada.

| Operaciones | Decisión en el custodio | Salida prevista |
| --- | --- | --- |
| session.get / session.logout | Verificar o revocar sesión actual | Identidad pública / confirmación y cookie |
| profiles.list / profiles.save / profiles.delete | Scope por identidad; revalidar dentro del escritor | Perfil saneado / confirmación |
| profiles.resolve / profiles.sync_youtube | Destinos upstream permitidos; sesión cuando proceda | Metadatos de canales, sin tokens |
| profiles.rotate_capability / profiles.unlink | Perfil autorizado y versión vigente | Capability nueva / confirmación |
| oauth.begin / oauth.complete | Permiso original revocable, browser binding, consumo único | URL oficial / cookie de sesión y redirección local |
| media.reserve / media.validate / media.save / media.preview | Permiso vigente, ledger, cuota y categoría | Reserva / metadatos / confirmación |
| media.read | Objeto activo validado y hash correcto | PNG/WAV validado |
| view.authorize / events.subscribe | Sesión de lector o capability de overlay vigente | Decisión / flujo SSE privado |
| health.ready | Estado agregado del custodio | Disponibilidad booleana |

`document` admite únicamente valores JSON acotados. Cada handler debe aplicar
además el esquema de dominio existente, autorizaciones y controles serializados;
el codec no los reemplaza. No hay operación de recuperar tokens, ejecutar SQL,
invocar módulos, reenviar HTTP arbitrario ni administrar el sistema.

Las subidas binarias no se embeben en JSON. `media.upload_authorize` verifica
la reserva y su tamaño antes de leer el cuerpo; `media.upload` vuelve a autorizar
antes de escribir. El límite de transporte es 2 MiB y el dominio impone además
los límites de categoría. La respuesta admite únicamente variantes cerradas,
cookies seguras y redirecciones locales u oficiales; rechaza claves de secretos.
Los objetos estáticos incluyen tamaño, MIME y SHA-256 que verifica el frente.
La respuesta privada tiene un presupuesto de 2800300 bytes: admite la expansión
Base64 de 2 MiB crudos y 4096 bytes de metadatos. El límite público JSON por
defecto sigue en 262144 bytes; SSE conserva su límite independiente de 2 MiB.

`events.subscribe` abre una conexión dedicada de TLS mutuo. El custodio conserva
la admisión, demanda de fuentes, replay, cursores y revocación del SSE existente.
El frente retransmite sus bloques acotados; no consulta eventos mediante polling.
La sesión del lector se revalida durante el flujo y la capability protege el
overlay. Las mutaciones de perfil revalidan su autorización dentro del escritor
serializado, incluso cuando esperaban en cola durante una revocación.

Las mutaciones requieren el Origin HTTPS configurado. La identidad del peer TLS
no concede permisos sobre perfiles. El proceso público rechaza al arrancar la
clave maestra, credenciales de plataforma/DB/media y estado privado de perfiles.
No se considera completo el protocolo ni ARCH06 hasta probar el aislamiento de
los procesos y los flujos reales, además de superar revisión y CI.

Las escrituras no se reintentan automáticamente después de una respuesta
incierta. Un fallo de transporte debe devolver indisponibilidad y conservar
la posibilidad de conciliación; no debe recurrir al backend local ni aceptar
claves de desarrollo. Preview mantiene caducidad/cooldown y no se reproduce
al reconectar. Una capability revocada debe cortar también SSE ya abierto.
