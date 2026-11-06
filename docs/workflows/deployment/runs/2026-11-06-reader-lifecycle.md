# Aceptación con fixtures del ciclo de lectores — 2026-11-06

Refs #47. Base `c016c06`, dependiente de la rama `fix/46-ci-build-recovery`. Solo fixtures: ni cuentas
ni plataformas reales, ni permisos de escritura, ni producción. No cierra #47.

## Qué se comprobó

`test/reader_lifecycle_test.exs` recorre `Source`, `Store`, `Tokens` y `Profiles` reales con upstream
falso, mirando lo que recibe el consumidor: mensajes, estado de la fuente, token usado y cuenta.

| Caso | YouTube | Twitch |
| --- | --- | --- |
| Expiración durante lectura | Mismo worker, token nuevo, sin hueco | Cierra el socket y reconecta con token nuevo |
| Refresh concurrente | 10 llamadas por perfil, un refresh por cuenta, sin cruzar tokens | Comparte el coordinador; no repetido |
| Rotación | Mismo enlace y worker; el refresh antiguo no se reutiliza | Sin caso propio |
| `invalid_grant` | Para ese lector, `reauth_required` visible y sin tokens; el otro perfil sigue; relink recupera | Para ese socket, `reauth_required`; el otro perfil sigue; sin relink. El estado queda `configuration_error` o `degraded` |
| Unlink y relink | Muere el worker, sin token antiguo; relink limpio | Unlink: muere el worker, sin reconexión |
| Parada de workers | Última visita fuera, worker bloqueado termina; un refresh sobrevive al lector que lo pidió | Sin caso propio |
| Revocación del proveedor | Sin caso propio | Error de configuración, sin reconexión inmediata |

El socket de Twitch solo sabe conectar al host real. La prueba lo sustituye en memoria durante la
prueba, sin cambiar código de producto.

## Defecto corregido

Un fallo transitorio de refresh (red, timeout o 5xx del proveedor) se presentaba en YouTube como
`configuration_error`, con 60 s mínimos de espera. El contrato pide distinguir fallos de autorización.
Ahora queda `degraded`, reintenta desde 5 s, conserva la cuenta y recupera. Un 403, 429, redirección,
respuesta 200 mal formada o error sin clasificar sigue siendo `configuration_error`. Las tres variantes de YouTube fallaban antes del cambio. También cambia Twitch, al conectar
y durante la lectura, con pruebas propias: antes paraba como `configuration_error` al conectar.

En estas pruebas el fallo lo produce un refresh iniciado por la propia prueba, y el worker hace cola
detrás: `Net.token` no permite inyectar el cliente HTTP, y así nada toca la red real. El resultado llega
al worker por el mismo camino, pero el worker no ejecuta ese refresh.

## Observado y sin cambiar

- Si el proveedor rechaza un token aún vigente localmente, el lector informa `configuration_error`
  y reintenta con el mismo token hasta que esté cerca de expirar; entonces el refresh lo resuelve.
- Por lectura del código, sin prueba: con el proveedor de tokens caído, un token vigente en sus últimos
  300 s no se usa, y el lector queda `degraded` hasta recuperar el refresh.
- Por lectura del código, sin prueba: al reconectar, Twitch limpia los mensajes mostrados, que es el
  comportamiento de hueco ya existente.

## Resultados y límites

Imagen de validación de esta rama, sin red, 2 CPU, 1 GiB, 128 PID. Prueba nueva, 22 casos, PASS en semillas 0 a 5.
Suite completa 351 PASS en semillas 0 y 424242, validador de informes PASS.

No probado: plataformas reales, PostgreSQL en estos casos, CI remota de esta rama, y navegador para el
aviso de reautenticación: solo se comprueba el resumen público que consume el panel.
Quedan en #47 la validación real limitada y autorizada. Rollback: revert.
