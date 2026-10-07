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
