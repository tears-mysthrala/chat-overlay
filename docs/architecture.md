# Arquitectura F2 y límites vigentes

Revisado el 05-11-2026 contra el código de `main` `2f26827` (Refs #41). Aquí se
distingue lo implementado en código, la última evidencia fechada y lo pendiente.
Ninguna evidencia fechada se repitió en esta revisión y no acredita por sí sola
`main` actual: el último registro de producción corresponde a PR #68 (08-10-2026).
Desde entonces cambiaron `recovery.ex`, el build de Postgrex y el launcher del decoder (#73). F2 sigue en
cierre de deuda ([backlog](backlog.md)); bots F3 y runners F4 no están autorizados.
Kick sigue diferido (#54): su código persiste, sin activación ni compromiso de uso.

## Roles de proceso

`CHAT_ROLE` selecciona el rol; un valor desconocido impide arrancar
(`Custodian.Role`, `custodian_role_test.exs`).

```text
Navegador / OBS -> proxy TLS del operador -> frontend (HTTP, assets, relay SSE)
                                               | TLS mutuo, protocolo v1 cerrado
                                               v
    PostgreSQL/RLS <- custodio: Profiles, Session, OAuthFlow, Tokens, Stores,
                      |         Admission, Sources, MediaCleanup
                      |-> Twitch / YouTube (destinos cerrados)
                      +-> coordinador multimedia -> decoder sin red ni secretos
```

| Rol | Supervisa | Frontera |
| --- | --- | --- |
| `frontend` | Solo `ChatOverlay.HTTP` con `Custodian.Frontend` | Rechaza arrancar con clave maestra, credenciales de DB/OAuth/plataforma/multimedia o estado de perfiles (`assert_safe_frontend!`). Conserva su clave de transporte mTLS. Si el custodio falla responde 503: no hay fallback local (`custodian_tls_test.exs`). |
| `custodian` | Persistencia, dominio y fuentes, más listener mTLS | Sin HTTP público. Rechaza peers sin certificado cliente; el certificado identifica el transporte, nunca al usuario. Ver [protocolo](custodian-protocol.md). |
| `combined` | Dominio y `ChatOverlay.Web` en una sola BEAM | Valor por defecto sin `CHAT_ROLE`, para demo y desarrollo. **No separa secretos** y no cumple ARCH-06. |

Última evidencia de la topología separada: dos releases sintéticas con
`scripts/check_custodian_isolation.py` y [corte del 08-10-2026](workflows/deployment/runs/2026-10-08-custodian-cutover-ui.md)
en VM Benten9502: frontend sin secretos en su entorno, custodio sin puertos
publicados y conexiones del frontend a PostgreSQL, coordinador e Internet
rechazadas. La cabecera de estado de [ADR0008](adr/0008-private-secret-custodian.md) y del
[protocolo](custodian-protocol.md) es anterior a ese corte. ARCH-06 **no está
cerrado**: #39 mantiene abierta su matriz operativa.

## Flujo de lectura y límites de runtime

```text
Configuración validada -> Registro OTP <- Store por perfil <- Source por fuente
                                             |                 | Task cancelable + Mint
                                             |                 | Twitch EventSub / YouTube API
                                             |
                                            SSE <- Admission (100 lectores)
                                             |
                       lector y overlay: assets propios + textContent
```

En roles separados, Store, Sources y Admission viven en el custodio; el frontend
abre una conexión mTLS por suscripción y retransmite bloques acotados
(`Custodian.StreamRelay`). Con `combined` todo ocurre en la misma BEAM.

El supervisor raíz usa `rest_for_one` para reconstruir dependencias de infraestructura; los supervisores de stores y fuentes usan `one_for_one`. Una fuente que cae no reinicia otra. Cada tarea está enlazada a su propietario y se cancela al perder demanda. Una fuente se comparte solo cuando plataforma, canal y contexto de credencial coinciden y su configuración es idéntica.

La primera vista activa la fuente; la última inicia una gracia de 60 segundos. El cierre TCP de un visor puede detectarse en la siguiente escritura/heartbeat (hasta 15 segundos adicionales). Admission libera explícitamente la reserva al finalizar SSE y monitoriza caídas. Los conectores no siguen leyendo indefinidamente sin lectores. El código de Kick (diferido) requiere suscripciones previamente aprovisionadas: sin demanda se verifican y descartan sus callbacks, sin conservar contenido.

Store tiene un único escritor, historial de 100 mensajes/30 minutos, replay de 512 eventos con caducidad y purga al borrar, deduplicación de 4096 claves y hasta 4096 barreras de borrado. Una inundación de borrados compacta todas las barreras del perfil, vacía el contenido y fuerza reset/degradado. Ninguna cola de mensajes por visor acumula el flujo: SSE consulta cambios cada 50 ms y escribe de forma síncrona. Un cursor caducado recibe snapshot; una escritura bloqueada tiene timeout de 5 segundos.

Límites de red del listener público: 4 aceptores con 128 conexiones máximas cada uno, 100 SSE globales (el listener mTLS usa 2 aceptores con 256), HTTP/2 desactivado, 30 cabeceras de 2048 bytes y línea de 2048 bytes, lectura HTTP 5 segundos. Los callbacks admiten 64 KiB y 250 solicitudes/s agregadas; TLS saliente usa destinos cerrados, DNS IPv4 público fijado a la conexión y verificación del hostname original. No se siguen redirecciones. Se rechaza IPv6 saliente para no introducir una segunda política incompleta.

Existe API de administración F2 de perfiles, sesiones, cuentas, tokens y multimedia; requiere autorización de perfil salvo el modo demo local delimitado. No hay ingestión general de chat. `/hooks/kick` solo existe en `ChatOverlay.Web`, con firma del cuerpo, frescura, suscripción y canal configurados; el frontend no tiene esa ruta y responde 404. Solo se confía en cabeceras de proxy procedentes de `CHAT_TRUSTED_PROXY_IPS`, para transporte y requester (`Transport`); no conceden identidad.

HTTP público termina TLS en un proxy del operador. Registro del [07-10-2026](workflows/deployment/runs/2026-10-07-public.md): `overlay.mysthrala.com` llega a la VM mediante un connector, con firewall limitado a ese connector. El servicio y sus assets comparten origen. No hay Phoenix, caché externa ni procesos shell durante el procesamiento de chats.

Las respuestas de YouTube tienen un presupuesto de 2 MiB para páginas de 200 recursos y selección explícita de campos; el resto de respuestas/frames se limita a 256 KiB. El handshake WebSocket rechaza respuestas distintas de 101 y acota el contenido recibido. Las esperas upstream sobreviven a cerrar y reabrir visores.

## Control F2

**Persistencia.** `CHAT_STORAGE` es obligatorio fuera de desarrollo: `postgres` o
`json_demo`; JSON nunca es fallback y no acredita RLS. Con PostgreSQL, dos pools
(`overlay_runtime` con RLS forzado y `overlay_bootstrap` de solo lectura) validan
identidad y permisos antes de arrancar el resto. `Profiles` serializa mutaciones y
actualiza memoria solo tras el commit. [Diseño y límites](postgres-storage.md);
[aceptación #51, 09-10-2026](workflows/deployment/runs/2026-10-09-persistence-acceptance.md)
con PostgreSQL real sintético. Ambos pools comparten la BEAM del custodio: RLS limita
errores de ámbito, no un custodio comprometido.

**Sesiones y OAuth.** `Session` cifra cookies y comprueba identidad, versión de cuenta
y perfil. Cada arranque, o la saturación de la lista de revocación, genera una época nueva que
invalida las cookies anteriores.
`OAuthFlow` liga el callback al navegador y al flujo autorizado, con consumo único;
`Tokens` coordina refresh con versiones y cancelación ante unlink/relink. Los lectores
Twitch/YouTube ya usan credenciales de propietario versionadas (#47 concilia su matriz
de fallos). Twitch real tras el corte consta en el
[registro del 08-10-2026](workflows/deployment/runs/2026-10-08-debt-closeout.md);
el callback nuevo de Google/YouTube no se ejecutó.

**Capabilities y revocación.** Las capabilities OBS se guardan como hashes y regenerarlas
desconecta los SSE de overlay del perfil (`Stream.disconnect_viewers`); los lectores con
sesión no dependen de la capability y siguen conectados. `events.subscribe` autoriza
antes de ocupar admisión y la sesión del lector se revalida durante el flujo
(`custodian_tls_test.exs`). Registro real del 08-10-2026: enlace anterior 401, actual 200.

**Multimedia.** `MEDIA_STORAGE` selecciona `local` o `r2` y cada objeto queda ligado a su
backend, sin migración automática. Ambos exigen coordinador configurado y dejan de emitir
subidas con `MEDIA_UPLOADS_SEALED=1`.

| Ruta | Implementado | Última evidencia |
| --- | --- | --- |
| Local ([ADR0006](adr/0006-local-media-storage.md)) | PUT del mismo origen, reautorizado en el custodio y reenviado por `LocalMedia` a `local_media_coordinator.py`; originales privados; `/media/local/*` (`media.read`) sirve solo salidas `ready`/`active` con SHA-256 verificado | [Aceptación local 09-10-2026](workflows/deployment/runs/2026-10-09-local-media-acceptance.md) con datos sintéticos; [panel real 07-10-2026](workflows/deployment/runs/2026-10-07-local-media.md); backend usado por el despliegue registrado |
| R2 | PUT prefirmado a un bucket privado de cuarentena, con coordinador separado; las salidas se promueven al bucket público | Solo almacenamiento sintético. **Nunca probado en una cuenta R2 real** |
| URL externa | Validación HTTPS, extensión y DNS público al guardar; el navegador la carga después | Sin inspección de bytes ni pinning de peticiones futuras; no entra en preview |

Ambas rutas de subida normalizan en un [decoder aislado](media-quarantine.md), sin red,
credenciales ni socket Docker, y publican PNG estático o WAV ligado a job y hash. El
coordinador y su launcher con acceso a Docker son servicio confiable del operador, fuera
del backend HTTP. `MediaLedger` y `MediaCleanup` conservan cuota e inventario hasta
confirmar el borrado. Según el código, el coordinador local valida el VEX del decoder al
arrancar: la revisión vencida el 2026-10-21 (#50) puede impedir su reinicio; estado
desplegado no comprobado. La [cabecera de cuarentena](media-quarantine.md) es anterior al
despliegue local. Preview es manual ([aceptación](workflows/deployment/runs/2026-10-09-preview-acceptance.md)):
no acredita eventos automáticos de follows/subs.

**Recuperación.** [Recuperación offline](recovery.md) prepara artefactos cifrados sin
arrancar workers; [fallos inyectados del 09-10-2026](workflows/deployment/runs/2026-10-09-recovery-faults.md).
No acredita corte eléctrico ni la operación continua de #38.

## Puertas abiertas

Estado de los issues comprobado el 05-11-2026:

- **Frontera y secretos:** #39 (ARCH-06, TLS/proxy), #69 (inyección del borde frente a CSP).
- **Multimedia:** #49 (aceptación global SEC-17), #48 (borrado y saneamiento), #32 (cuotas), #63 (escalado, sin implementar).
- **Validación:** #42 (ASVS), #43 (navegador/OBS, Google), #44 (conectores reales), #47 (matriz OAuth de lectores), #34 (carga: `main` solo registra 4 h aceptadas).
- **Distribución y operación:** #4, #35, #36, #37, #38, #45, #46, #50.
- **CI:** la [ejecución de `main` del 02-11-2026](https://github.com/tears-mysthrala/chat-overlay/actions/runs/41474962609) sobre `2f26827` falló en auditoría de dependencias y build del decoder; no corregida ni repetida en esta revisión. Bloquea el merge (#50).

Un único coordinador de producto activo está soportado; varias instancias necesitan
coordinación adicional. Ver [modelo de amenazas](threat-model.md) y [verificación](verification.md).
