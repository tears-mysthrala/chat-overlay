# Custodio privado — Refs #39

## Alcance y baseline

Kalista aprobó expresamente la implementación y pruebas del ADR0008 el
07-10-2026. Bots/F3 y nuevas dependencias quedan fuera del alcance. Autorización
previa de despliegue vigente; el corte espera integración, revisión y CI.

Worktree `D:\github\_worktrees\chat-overlay-39-custodian`, rama
`security/39-private-custodian`, baseline main
`2e09fc4aff92b5f2de53c5dcbbb39cb27fb894b3`. Sin cambios existentes al crearla.
El registro postmerge sin commit de ops40 se conserva en su worktree original.

## Trabajo actual

Lectura de contrato, ADR, supervisor, configuración runtime, rutas Web y SSE.
Confirmado por código: la misma BEAM conserva secretos y atiende HTTP público.
Codec v1 cerrado para sesión, perfiles, OAuth, medios y eventos; rechaza campos
arbitrarios y decisiones de autorización suministradas por el frente.
Diseño de autenticación: TLS mutuo con CA interna independiente, usando las
dependencias existentes. Sin listener interno ni modificación de producción.

Validación en la imagen Linux existente `chat-overlay:64-preview-validation`
(`a5182323f653`), copiando las fuentes/config/test del worktree a su build
efímero: sin red, 2 CPU, 1 GiB, 128 PID y `ERL_FLAGS=+S 2:2`.
`mix format --check-formatted`, `mix compile --warnings-as-errors`: PASS.
Primera revisión: suite seed0, 299 PASS. Revisión final con dos negativos
adicionales: suite seed424242, 301 PASS, 0 fallos. No extrapolar ese resultado
a mTLS, dos procesos, PostgreSQL, CI o producción, todavía no ejecutados aquí.
`python scripts/security_static.py`: 0 hallazgos en sus reglas limitadas.
`python scripts/scan_secrets.py`: sin fugas detectadas.
`git diff --check`: PASS. El primer helper de shell falló con
`helper_unknown_error: setup refresh had errors`; lectura escalada funcionó.

## Puertas pendientes

Codec de salida y subida binaria; handlers reales con permisos serializados;
roles y mTLS; lectores/SSE y multimedia; pruebas entre procesos; revisión
oficial OpenAI; CI; merge; despliegue reversible y prueba OBS/OAuth real.
No se declara ARCH06 cerrado ni separación efectiva implementada todavía.

## Integración y comprobaciones posteriores

Implementados roles de supervisor separados, RPC mTLS con operaciones cerradas,
respuestas saneadas, frontal HTTP, retransmisión SSE y subidas binarias con
autorización antes de leer y antes de escribir. El escritor revalida permisos
al procesar la operación, incluida una revocación previa mientras esperaba.
Pruebas dirigidas: 28 PASS, con certificados sintéticos y transportes TLS reales.
La prueba de subida usa almacenamiento simulado: no acredita el decoder real.

La suite completa detectó una condición SSE que recibía nil y la pérdida del
campo público last_error. Corregidas ambas regresiones. Imagen de validación
61a8a2160b2a80aa1e889e90edd7f8b07d2622c7652035ebe98d0946a8646d62:
seed0/max_cases1 y seed424242/max_cases16, 323 PASS por ejecución, 0 fallos.
Controles estáticos limitados: 0 hallazgos; escaneo de secretos: sin fugas;
git diff --check: PASS. Release local fcb08dc49a5f2184147a0422835599b92e50307f2193ae249bd6ff36e13964b5.

Prueba entre dos contenedores: pendiente. La red Docker internal del candidato
impide publicar el HTTP del frente. La revisión automática rechazó retirar
internal: true y depender de harden.sh para bloquear su salida: requiere
aprobación explícita de ese cambio de conectividad. El cambio rechazado no se
aplicó. Compose y producción conservan su configuración previa. No hay resultado
PASS de aislamiento, revisión oficial, CI, merge ni despliegue de esta candidata.

El operador aprobó expresamente el ajuste de conectividad en la respuesta
posterior. Retirado internal de boundary; harden.sh custodian debe aplicarse
antes de arrancar la topología para impedir nuevas salidas del frente salvo
172.30.98.3:4200. No se aplicó todavía en Benten.
Prueba local con dos releases y CA/sesión sintéticas: PASS. Namespaces PID
distintos, UID65532 y rootfs readonly; frente sin credenciales ni perfiles,
perfil autorizado vía mTLS, custodio sin puerto publicado y 503 al detenerlo.
Evidencia: output/custodian/isolation.json, release fcb08dc49a5f.
No acredita el firewall del huésped, PostgreSQL, upstream OAuth ni decoder.

## Revisión de candidata y corrección funcional

Commit97312b5 publicado como PR #67, listo para revisión y enlazado en T3.
Revisión oficial OpenAI875c8b69-a847-4343-b47d-a668494d3dfb completada:22 archivos
fuente, dos reviewers Sol con reparto8/8 y seis operativos revisados por padre.
Sin vulnerabilidades confirmadas; dos bloqueos funcionales conservados en notas:
formato de cookie OAuth y límite Base64 menor que audio crudo admitido.
Contador del goal de revisión:259715 tokens,782 segundos; no es medida de tokens
facturados. El contador del plugin agrega caché/input de las conversaciones.

Corregido sufijo real de cookie32hex lowercase, también en borrado; presupuesto
cerrado privado2800300bytes para2MiB raw+Base64+metadatos. Defaults públicos y
profundidad JSON preservados. Regresiones dirigidas:15PASS, incluyendo inicio y
callback cancelado de ambos proveedores por mTLS, audio máximo por ruta real con
almacenamiento sintético, hashes/tamaños inválidos y negativos TLS. No upstream.
La primera ejecución de integración PostgreSQL omitió la migración del fixture
y falló; repetido orden exactoCI con identidad migrator:26PASS porseed y boot/
write/restartPASS. 12regresionesLinuxPythonPASS. Auditoría releasefcb08dc49a5f:
295componentes CycloneDX schema válido;0pendientes,4matches porVEX previamente
aprobado. La imagen corregida requiere su propia identidad y CI; no extrapolar.

Correcciones locales finales: 327 ExUnit PASS en seeds 0/424242, serial y
concurrente, en validation6ff8abfb4106. 16 pruebas dirigidas PASS. El primer
ensayo de 100 streams dejó reservas transitorias al cerrar sockets y afectó a
otras pruebas; ahora revoca la sesión real y verifica la liberación natural
antes de continuar, sin reiniciar ni vaciar Admission. Capacidad privada
alineada a la pública: ThousandIsland limita por aceptador, 2x256 frente a
4x128; admisión SSE conserva100. Formato y diff check PASS.
CI97312b5 falló por ConnectionResetError al arrancar el comprobador; el retry
acotado de readiness incluye ese error, sin reintentar mutaciones.
Release8f4b1a79bcb5: aislamiento dos contenedores y smoke PASS;
SBOM295 schema válido, cero pendientes y cuatro coincidencias cubiertas por
VEX aprobado. Falta CI de las correcciones, revisión de su delta y producción.
