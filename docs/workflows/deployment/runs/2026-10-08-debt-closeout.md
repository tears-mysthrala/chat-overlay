# Reconciliación de deuda y continuación F2 — 08-10-2026

Refs #55, #41, #34. El operador solicitó crear los issues de deuda, actualizar el
backlog y continuar el plan. Se reutilizan tickets existentes; no se activan F3,
F4 o Kick ni se modifica producción en esta unidad documental.

## Base y evidencia

- `origin/main` comprobado mediante GitHub y fetch: `640ef847d6dd76b2f3bbc7f41a902e50df3b1698`, PR #68 integrada.
- Worktree separado `chat-overlay-55-debt-closeout`, rama `docs/55-debt-closeout`; checkout principal y trabajo previo preservados.
- Imagen desplegada registrada: `sha256:2d72630856a9324f184f0cf11f3dd9e15303f79c82fbc50ac7276cd2b69470f8`.
- Reconstrucción documental desde `output/cutover/postcutover-live-tests.md` del worktree de corte, leído en esta ejecución. No son nuevas pruebas de producción.
- OAuth Twitch real y mensaje único autorizado mostrados en lector/OBS. Alerta manual con imagen y señal de audio; audibilidad confirmada por el operador. Revocación comprobada: enlace anterior401, actual200; fuentes OBS actualizadas y escena restaurada.
- Callback nuevo Google/YouTube tras el corte no ejecutado. El rechazo CSP de una inyección del borde queda en #69.

## Inventario

[Backlog vigente](../../../backlog.md), sincronizado al issue #55. Reconciliados
#32/#34/#38–#41/#43/#46/#47/#49/#51/#52/#62/#64 sin cierres automáticos.
Nuevos #69 (CSP/borde) y #70 (deprecación xref). La aceptación original se conserva
en los tickets bajo la actualización fechada.

## Continuación: carga local

Build `docker build --target validation -t chat-overlay:55-closeout-validation .`
terminó correctamente; imagen `sha256:d4a26881f8d7642b7a8407df1a491f0eec3ab8dfe3f60e91e568a6a08f7ec840`.
Formato y compilación del producto pasaron. Se reprodujo el aviso de #70 y se
localizó en `deps/postgrex/mix.exs:17`: `xref: [exclude: [Jason]]`.
No se modificó ni silenció la dependencia.

Prueba de arranque de30 s PASS: 30.000/30.000 entregas, cero errores, p95 de50 ms.
Ejecución de4 h iniciada en el contenedor `overlay34-4h-640ef84` el08-10-2026
alrededor de21:00 UTC; salida final todavía pendiente. Ambas usan `--network none`,
2 CPU, 1 GiB sin swap adicional, 128 PIDs y `ERL_FLAGS=+S 2:2`; 10 perfiles,
30 fuentes demo, 100 lectores. No acceden a plataformas ni datos de producción.
`LOAD_SOURCE_COMMIT` identifica la base640ef84; cambios de esta rama son documentales.
Es una imagen de validación con herramientas de prueba, no el digest del runtime.

Las ejecuciones prolongadas solo se aceptan al revisar salida final, entrega,
p95, errores, OOM y tendencia de recursos. La de24 h se inicia después de aceptar
la de4 h. El informe final permanece pendiente hasta terminar cada ejecución.
Estática específica: cero hallazgos (reglas limitadas); scanner de secretos:
cero fugas; revisión del diff documental y `git diff --check` sin errores.

## Siguiente acción

Conservar salida e inspección Docker bajo `output/debt-closeout/`; analizar #34 y
actualizar verificación. Completar aceptación de tickets implementados con pruebas
específicas, sin extrapolar estos resultados a distribución, ASVS o Google OAuth.
