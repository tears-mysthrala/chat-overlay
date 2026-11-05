# Modelo de amenazas F1/F2

Revisado el 05-11-2026 contra `main` `2f26827` (Refs #41). Las evidencias citadas
conservan su fecha; no se repitieron en esta revisión ni acreditan `main` actual.
"Sintético" significa fixtures o datos de prueba, nunca cuentas ni tráfico real. Este
documento no autoriza publicación y no contiene reproducciones sensibles (DEV-09).

Activos: clave maestra, credenciales OAuth y de DB, tokens de lectura, capabilities y sesiones, archivos subidos, disponibilidad, integridad del overlay y separación de perfiles. Entradas no confiables: visitantes HTTP, archivos multimedia, mensajes y errores upstream, DNS, callbacks y dependencias. La configuración del operador es una entrada privilegiada validada; nunca procede de una URL pública.

## Fronteras F2 vigentes

| Frontera / abuso | Implementado en código | Última evidencia fechada | Riesgo residual y puerta |
| --- | --- | --- | --- |
| Frontend público comprometido | Rol sin secretos ni perfiles (`assert_safe_frontend!`); solo operaciones v1 cerradas sobre mTLS | Dos releases sintéticas; [corte 08-10-2026](workflows/deployment/runs/2026-10-08-custodian-cutover-ui.md): secretos ausentes y salidas bloqueadas | Conserva su clave de transporte; puede capturar sesiones, capabilities y bytes que lo atraviesan e invocar operaciones como cualquier usuario cuya credencial capture. ARCH-06 abierto (#39) |
| `origin`/`requester` falsificados por ese frontend | El custodio no deriva permisos de ellos; límites agregados en Admission y OAuthFlow | `custodian_tls_test.exs`, `oauth_flow_test.exs`, sintético | Puede agotar cupos agregados o anónimos; #39/#42 |
| Custodio comprometido | Sin puertos publicados, rootfs readonly, sin capabilities | Corte 08-10-2026 | Accede a clave maestra y a ambos pools: lectura global y contextos RLS. Esta arquitectura no lo mitiga |
| Despliegue en rol `combined` | Valor por defecto sin `CHAT_ROLE`, para demo/desarrollo | No aplica | Una BEAM con secretos y HTTP público: no usar para publicar; ARCH-06 |
| Fuga entre perfiles en DB | RLS forzado, contexto por transacción, roles validados al arrancar | [Aceptación #51, 09-10-2026](workflows/deployment/runs/2026-10-09-persistence-acceptance.md): rol/pool reales, datos sintéticos, 26 PASS por seed | Sin prueba de RLS adversaria en producción; JSON no acredita RLS; una sola instancia coordinadora soportada |
| Cookie robada, de otro perfil o tras unlink | Cookie cifrada, identidad/versión/perfil; época por arranque; revalidación dentro del escritor | `session_test.exs`, `web_session_auth_test.exs`, `custodian_tls_test.exs`, sintético | Una cookie robada sigue siendo válida hasta expirar o revocarse |
| Callback OAuth falso o de otro navegador | Binding de navegador, consumo único, cuotas | `oauth_flow_test.exs`, `web_oauth_test.exs`; Twitch real [08-10-2026](workflows/deployment/runs/2026-10-08-debt-closeout.md) | Callback nuevo Google/YouTube sin ejecutar (#43); matriz de lectores #47 |
| Capability OBS filtrada o revocada | Hash en reposo, comparación constante, rotación con desconexión SSE | `web_f2_test.exs`; enlace antiguo 401 y nuevo 200 en real, 08-10-2026 | Viaja en la URL de OBS: su exposición en capturas o registros del proxy dura hasta rotarla; rotar la clave maestra no la revoca |
| Archivo hostil o MIME falso | Cuarentena, validación estructural, decoder sin red/credenciales/socket, salida PNG/WAV ligada a hash | [Local 09-10-2026](workflows/deployment/runs/2026-10-09-local-media-acceptance.md), bytes reales de fixture; decoder en CI | Kernel/daemon/host fuera de frontera; backport Python y decoder sin VEX aprobado; aceptación global #49; originales grandes #63 |
| Coordinador multimedia alcanzado | Token dedicado; solo accesible desde el custodio por firewall; destino fijo | [Despliegue 07-10-2026](workflows/deployment/runs/2026-10-07-local-media.md) | HTTP con bearer sin TLS en bridge privado; servicio de root con acceso a Docker: compromiso equivale a host |
| PUT tardío o reutilizado | Tombstones locales; PUT condicional en R2; reconciliación sellada | Almacenamiento sintético | R2 **nunca probado** en cuenta real; drenaje real sin acreditar; inventario heredado #48 |
| Borde/proxy | TLS en proxy; `CHAT_TRUSTED_PROXY_IPS` explícito; CSP sin `unsafe-inline` | [Publicación 07-10-2026](workflows/deployment/runs/2026-10-07-public.md) | El borde ve cookies y capabilities; inyección rechazada por CSP (#69); acceso directo y reemplazo de cabeceras dependen del operador (#39) |

## Controles generales

| Abuso | Control implementado y evidencia | Límite residual |
| --- | --- | --- |
| XSS desde chat | textContent, CSP, assets locales; caso literal HTML en demo y prueba DOM | OBS real: evidencia histórica #21 y alerta/mensaje del 08-10-2026, no repetidas sobre `main` actual; inyección del borde en #69 |
| SSRF/red doméstica | hosts cerrados, IP pública fijada, TLS/hostname, sin redirects, HEAD/DELETE multimedia solo al endpoint del operador | DNS falla cerrado; solo IPv4 |
| Fuga entre perfiles | stores por handle, selección configurada, fuentes/autorización identificadas; tests A/B | Sesiones comprueban perfil/identidad/versión; RLS en la tabla anterior; JSON no acredita RLS |
| Robo de token | env solo en el custodio con roles separados, cabeceras salientes, errores cerrados, format_status redactado | Administrador del host y volcados de la VM del custodio pueden acceder; proteger el host |
| Callback Kick falso/replay (diferido, #54; sin ruta en rol `frontend`) | RSA SHA-256 con clave oficial, timestamp ±300 s, IDs y dedup; pruebas de firma/tamper | Rotación de clave requiere actualización revisada; no conserva una cola durable |
| Saturación | límites de JSON, cuerpos, historial, replay, tombstones, SSE, conexiones, escritura y contenedor | Con roles separados, SSE exige sesión o capability antes de admisión, pero quien tenga una válida puede ocupar las 100 plazas y las peticiones anónimas consumen conexiones del frontend; sin cuota por IP acreditada en origen. En `combined`, además, el cupo de callbacks Kick. Carga: `main` registra 4 h sintéticas aceptadas; #34 abierto |
| Resurrección tras borrado | barreras por mensaje/autor/canal, compactación, reset y limpieza tras huecos | Kick no proporciona borrado individual en la API usada |
| Caída de lector | tareas enlazadas, gracia, supervisión independiente; prueba de kill/reinicio | Corte completo del proceso pierde historial |
| Dependencia vulnerable | lock, digests, Hex audit, inventario, Grype con VEX fechado y auditado | Revisión de excepciones debida 2026-10-21 **vencida** sin cierre registrado; #50 abierto el 05-11-2026. Ver dependencies.md |
| Administración expuesta | sesión y autorización por perfil, métodos limitados, excepción demo local | Origen público registrado el 07-10-2026 (API anónima 401); revisión TLS/proxy #39 y gates de publicación #4 pendientes |

No hay eval, átomos externos, shell de usuario, deserialización Erlang de datos de chat, HTML arbitrario, telemetría o llamadas a modelos. Los scripts de inventario procesan metadatos de build y no forman parte del servidor.

## Registro histórico: superficies F2 y deuda (2026-10-02)

Instantánea conservada; **no describe el estado vigente**. Desde entonces se integraron
cuarentena, PostgreSQL/RLS y separación de custodio: las filas de MIME falso y de
proceso público comprometido ya no son actuales. Consultar [fronteras vigentes](#fronteras-f2-vigentes).

| Abuso | Evidencia candidata | Pendiente / límite |
| --- | --- | --- |
| Cookie de otro perfil o posterior a unlink/relink | `session_test.exs`, `web_session_auth_test.exs`, `tokens_test.exs` y gates de ciclo de vida | No acredita aislamiento de filas en almacenamiento (#51) |
| Callback OAuth sin flujo ligado o identidad equivocada | `oauth_test.exs`, pruebas web de sesión/OAuth | Revalidar E2E y proveedor real por separado (#43/#44) |
| Carrera entre refresh, unlink y persistencia | `token_lifecycle_gate_test.exs`, `profile_persistence_test.exs` | JSON, memoria y workers no constituyen una transacción distribuida |
| Reservas concurrentes o borrado R2 fallido | `media_ledger_test.exs`, `web_f2_test.exs`; PR #57 | Inventario heredado pendiente de conciliación (#48) |
| Archivo con MIME falso, decoder hostil o PUT reutilizado | Metadatos firmados/HEAD solo acotan la petición | Cuarentena, bytes reales y salida inmutable **pendientes** (#49) |
| Copia o rotación de clave incompleta | `recovery_test.exs`, copia AEAD y destinos nuevos | Ensayo sintético offline; no corte eléctrico ni recuperación real |
| Proceso público comprometido lee todos los secretos | Ninguna afirmación de aislamiento suficiente | ARCH-06/#39 y SEC-13 bloquean publicación |

## URLs externas

Las URLs externas se cargan en el navegador; la comprobación DNS al guardarlas no
es pinning de futuras peticiones del navegador ni inspección del archivo. Su uso
requiere origen confiable y política CSP; no se declara eliminada toda SSRF/XSS por
validar una extensión. No se publican aquí reproducciones sensibles (DEV-09).

## Transacciones OAuth — #42

El callback HTTP exige el estado cifrado y la cookie HttpOnly del navegador que
inició el flujo. El registro privado de hashes consume la pareja de forma atómica,
antes del intercambio remoto, también ante denegación del proveedor o fallo.
La cookie usa SameSite=Lax para el retorno GET y Secure cuando el transporte
usa TLS directo o procede de una IP de proxy explícitamente configurada en
`CHAT_TRUSTED_PROXY_IPS` con una única cabecera `X-Forwarded-Proto: https`.
Sin proxy configurado no se confía en esa cabecera. El operador debe impedir
acceso directo y hacer que el proxy reemplace las cabeceras del cliente; esta
frontera tiene un recorrido real registrado (Twitch, 08-10-2026), pero su revisión sigue abierta en #39. Fuera de
loopback no se inicia un flujo sobre HTTP no confiable.

El registro admite 1024 transacciones, hasta 512 anónimas, cuatro anónimas por
perfil y solicitante y ocho autorizadas por perfil, con vida de diez minutos y
limpieza al acceder. Conserva hashes e instantáneas de identidad/autorización;
un reinicio cancela los flujos pendientes. Cada transacción tiene una cookie
independiente que se borra al consumirla; HTTPS usa el prefijo `__Host-`.
La escritura revalida la sesión y la instantánea dentro del escritor serializado.
NAT y peers de proxy sin XFF único verificado comparten la cuota anónima.
Ver [configuración y límites](oauth-runtime.md).
No se acredita coordinación entre réplicas ni callback nuevo de Google/YouTube, ni se
sustituye la autorización vigente del perfil por el binding del navegador.

## Frontera de recuperación offline — #40

Activos: clave maestra, documento de perfiles, credenciales cifradas y copias.
Solo el operador autorizado ejecuta `scripts/recovery.exs`; las rutas, archivos y
artefactos importados requieren validación, aunque procedan de una copia local.
La herramienta se ejecuta con `--no-start`, sin conectores ni configuración real
de red. No establece una frontera contra un administrador del host comprometido.

| Abuso | Control | Riesgo residual |
| --- | --- | --- |
| Clave expuesta o ruta de clave no privada | Archivo regular sin symlink, permisos POSIX privados, tamaño acotado; claves fuera de argumentos/logs | lstat/read no es una apertura inmune a carreras: directorio y host deben ser confiables; Windows ACL no validada |
| Copia manipulada, truncada o con otra clave | AEAD, AAD de dominio/versión/key_id, límites y validación del documento y credenciales | El cifrado no impide restaurar una copia válida pero antigua |
| Destino existente o symlink | Staging privado y publicación por hard-link sin sobrescritura | Directorio padre debe ser confiable; fsync de archivo no acredita durabilidad del directorio |
| Restauración resucita permisos o refresh tokens | Parada previa de escritores, conciliación y reautenticación antes del cambio | La herramienta no comprueba parada ni revoca upstream; decisión del operador |
| Rotación incompleta o mezcla de generaciones | Verificación de todas las credenciales, salida nueva, cambio coordinado de documento/clave | Cookies y OAuth pendientes se invalidan; capabilities OBS y secretos externos necesitan revocación separada |

Las pruebas sintéticas de `recovery_test.exs` verifican errores, integridad y
publicación privada; [ENOSPC/EIO/SIGKILL durante staging](workflows/deployment/runs/2026-10-09-recovery-faults.md)
constan el 09-10-2026 con fixtures. No son un ensayo de corte eléctrico ni de
recuperación de producción. Una muerte del proceso deja un staging privado que no se
limpia solo. Periodicidad y custodia redundante siguen en #38. Conservar inventario multimedia al restaurar y custodiar las claves
separadas de las copias, con retención y eliminación autorizadas.
