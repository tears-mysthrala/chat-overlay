# Protocolo privado v1 — Refs #39

Estado: codec de entrada en implementación; transporte y handlers pendientes.
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
| view.authorize / events.read | Vista y capability vigente en cada lectura | Decisión / eventos normalizados acotados |
| health.ready | Estado agregado del custodio | Disponibilidad booleana |

`document` admite únicamente valores JSON acotados. Cada handler debe aplicar
además el esquema de dominio existente, autorizaciones y controles serializados;
el codec no los reemplaza. No hay operación de recuperar tokens, ejecutar SQL,
invocar módulos, reenviar HTTP arbitrario ni administrar el sistema.

Las subidas binarias no se embeben en JSON: necesitan una operación de carga
separada, vinculada a una reserva autorizada y con el máximo real de su categoría.
Esta operación todavía no se habilita. También quedan por definir el codec de
respuesta, cursores y ciclo de demanda de SSE antes de conectar transporte.
No se considera completo el protocolo ni ARCH06 hasta probar esos flujos reales.

Las escrituras no se reintentan automáticamente después de una respuesta
incierta. Un fallo de transporte debe devolver indisponibilidad y conservar
la posibilidad de conciliación; no debe recurrir al backend local ni aceptar
claves de desarrollo. Preview mantiene caducidad/cooldown y no se reproduce
al reconectar. Una capability revocada debe cortar también SSE ya abierto.
