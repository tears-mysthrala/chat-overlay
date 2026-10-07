# ADR 0008 — Custodio privado de secretos — Refs #39

Estado: propuesta concreta; no implementada ni aprobada por este ADR.

## Problema y decisión propuesta

El proceso BEAM que atiende HTTP público conserva la clave maestra, OAuth,
credenciales PostgreSQL y coordinación de tokens. RLS y el proxy Cloudflare no
separan esa superficie de la custodia de secretos. Un compromiso de ese proceso
puede acceder a todos ellos. No se declara ARCH06 cerrado.

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

## Pendiente de decisión

Aprobar la separación y el protocolo privado tipado para implementación y
pruebas, manteniendo bots/F3 y nuevas dependencias fuera del alcance. El diseño
detallado debe especificar autenticación interna antes de activar cualquier RPC.
