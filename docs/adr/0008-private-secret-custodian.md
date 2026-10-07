# ADR 0008 — Custodio privado de secretos — Refs #39

Estado: implementación y pruebas aprobadas explícitamente por Kalista el
07-10-2026 en la conversación del proyecto. Separación todavía no implementada
ni acreditada en producción.

## Problema y decisión propuesta

El proceso BEAM que atiende HTTP público conserva la clave maestra, OAuth,
credenciales PostgreSQL y coordinación de tokens. RLS y el proxy Cloudflare no
separan esa superficie de la custodia de secretos. Un compromiso de ese proceso
puede acceder a todos ellos. No se declara ARCH06 cerrado.

Evidencia del checkout196a12d: `Application.start/2` en
`lib/chat_overlay/application.ex` supervisa Bandit/Web, Profiles y Tokens en la
misma aplicación/BEAM; `config/runtime.exs` configura los pools PostgreSQL desde
CHAT_DB_RUNTIME_PASSWORD/CHAT_DB_BOOTSTRAP_PASSWORD; `OAuth.encryption_key/0`
lee CHAT_ENCRYPTION_KEY, y `Profiles.get_linked_account_auth/2` descifra tokens
en esa BEAM. Los OAuth client secrets se leen en `lib/chat_overlay/oauth.ex`.
`deploy/benten/compose.yaml` entrega runtime.env a ese único servicio overlay.
El coordinador multimedia sí es otro proceso systemd, con credencial separada;
no conserva los client secrets OAuth ni sustituye la custodia del backend.

Separar dos roles usando el mismo repo y las dependencias Elixir existentes:

- Frente público: parsers HTTP acotados, frontend, SSE y eventos normalizados.
  Sin clave maestra, credenciales DB, OAuth client secrets o tokens recuperables.
- Custodio privado: sesiones, comprobación de permisos, OAuth/refresh, escritor
  de perfiles, PostgreSQL y lectores autorizados. Sin puertos publicados. Devuelve
  únicamente metadatos permitidos, decisiones de autorización y eventos saneados.

El límite utiliza operaciones internas tipadas y cerradas; no es un proxy de
HTTP arbitrario, SQL, nombres de módulos o llamadas Erlang. No habilitar
distribución Erlang ni exportar tokens a través del límite. El custodio revalida
sesión/versión/handle dentro de cada mutación serializada. No confía en un
`authorized=true` enviado por el frente. Canales internos autenticados, deadlines,
límites de tamaño y backpressure, red sin acceso desde LAN/Internet.

## Contratos y aceptación antes de implementar

El protocolo privado es un contrato nuevo y la separación cambia arquitectura
y permisos efectivos. Requiere decisión explícita del propietario según
WHAT_WE_ARE_BUILDING.md: «Cambiar [...] la retención, las fronteras entre clientes
o las condiciones de publicación exige issue, justificación y aprobación».
La continuación general autoriza preparar el diseño, no acredita el protocolo.

Primera unidad: matriz de operaciones de sesión/perfil/OAuth y eventos por
versión; fixtures negativas de handle cruzado, revocación y replay. Segunda:
roles de proceso y transporte interno con pruebas de ausencia efectiva de
secretos en entorno/mounts del frente. Tercera: conectar los lectores y flujo
multimedia completos, CI, revisión oficial y prueba OBS/callbacks reales antes
del corte. No entregar una separación simbólica o mocks desconectados.

Despliegue reversible en Benten, preservando DB, claves, medios y credenciales.
Rollback de imagen/configuración sin restaurar snapshots antiguos. Una caída
del custodio debe degradar y rechazar escrituras; el frente no usa claves de
desarrollo ni una ruta alternativa local. Un frente comprometido aún puede
robar sesiones que circulen por él; esta arquitectura limita exposición de
secretos, no promete inmunidad a todas las acciones del usuario autorizado.

## Autenticación interna y siguiente unidad

La aprobación cubre la separación y el protocolo privado tipado, manteniendo
bots/F3 y nuevas dependencias fuera del alcance. El canal será TLS mutuo con una
CA dedicada al protocolo, usando OTP SSL, Bandit y Mint ya presentes. El
custodio requiere certificado de cliente; el frente verifica CA y hostname del
custodio. Certificados de transporte separados de la CA PostgreSQL y de las
credenciales OAuth. No se acepta TLS sin verificación ni un secreto Bearer como
sustituto. El certificado del frente identifica el transporte, no al usuario:
cada operación sigue requiriendo la autorización vigente del usuario.

El frente necesariamente conserva su clave privada de transporte. La ausencia
de secretos exigida por ARCH06 se refiere a la clave maestra, contraseñas DB,
client secrets OAuth, credenciales del coordinador y tokens de plataforma.
Comprometer el frente permite invocar las operaciones públicas como ese frente;
no concede acceso genérico al custodio ni una identidad administrativa.

El protocolo v1 se documenta en `docs/custodian-protocol.md`. Su codec no activa
un listener ni cambia el despliegue. El corte queda bloqueado hasta conectar
todos los flujos, validar dos procesos reales y completar revisión/CI/OBS.
