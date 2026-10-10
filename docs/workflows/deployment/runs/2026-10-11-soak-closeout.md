# Cierre de carga 4 h / 24 h — 11-10-2026

Refs #34, #4, #55. Se inspecciona el contenedor existente sin reiniciar ni duplicar
la prueba. Host: Docker Desktop Linux sobre el equipo Windows del operador.
La candidata medida es `640ef847d6dd76b2f3bbc7f41a902e50df3b1698`, no HEAD posterior.
Imagen `sha256:d4a26881f8d7642b7a8407df1a491f0eec3ab8dfe3f60e91e568a6a08f7ec840`,
Elixir 1.20.4, OTP 29, dos schedulers; network none, 2 CPU, 1 GiB sin swap,
128 PIDs. Diez perfiles, treinta fuentes y cien lectores SSE locales.
Carga: 200 eventos/s durante diez segundos y 50/s después; texto de 512 bytes,
con el overhead demo declarado. Instrumentación y metodología ya integradas.

## Resultado comprobado

Las [cuatro horas](2026-10-09-soak.md) terminaron con 7.215.000 entregas exactas,
cero errores y p95 de 50 ms. El primer intento de 24 h se interrumpió durante
el reinicio de Windows: exit 255, sin informe, no aceptado ni sumado a otro.

La repetición `overlay34-24h-640ef84-retry1`, ID
`7c9683eb6870df469a5e796f2fb0de7a86e97df5f1b5adc7a32aa05c85936c0e`, terminó
el 10-10. Inspección final: exited, exit 0, OOM false, sin error de Docker.
Su informe contiene 4.321.500 eventos emitidos, 43.215.000 entregas esperadas
**y recibidas**, cero errores y p95 local a SSE de 50 ms, por debajo de 100 ms.
Duración monotónica medida: 86.400.203 ms. No se toma exit 0 como única prueba.

Hay 1.440 muestras por minuto durante la carga, sin huecos ni duplicados,
todas con 549 procesos y cero errores. Tras el calentamiento, medias horarias
2–24 entre 427,402 y 429,119 MB; última hora 428,850 MB, máximo muestreado
433.948.824 bytes. No se observa crecimiento sostenido en esta ventana.
La muestra final de 349 procesos y 155.975.264 bytes se excluye del análisis
durante carga: pertenece al cierre de los cien lectores, no acredita estabilidad.

Los timestamps UTC del informe abarcan 86.395,985 s, unos 4,218 s menos que el
reloj monotónico. Se preservan ambos sin corregirlos ni atribuir una causa no
comprobada. La duración del generador se gobierna por System.monotonic_time,
verificado en scripts/load.exs de la candidata; la emisión y muestras completan
la ventana programada. La inspección Docker abarca 86.402,586 s.

## Evidencia y reproducción del análisis

- [Informe íntegro](../evidence/2026-10-11-soak/load-24h.json), SHA-256
  `18815159732977e8cd92215e4c6ba0594e07439d6edd47e851a69ccc6c3c0333`.
- [Inspección final filtrada](../evidence/2026-10-11-soak/load-24h-inspect.json):
  identidad, comando, estado y límites; sin entorno ni rutas privadas.
- [Resumen por hora](../evidence/2026-10-11-soak/analysis.json) y
  [analizador](../evidence/2026-10-11-soak/analyze.py). Las medias usan MB decimales.

Desde la raíz, ejecutar `python docs/workflows/deployment/evidence/2026-10-11-soak/analyze.py docs/workflows/deployment/evidence/2026-10-11-soak/load-24h.json`.
El resumen reproducido coincide con el conservado. El mismo analizador acepta
el informe de cuatro horas. Excluye la muestra de cierre y calcula ventanas
horarias independientes; no declara automáticamente ausencia de fugas.

Se aceptan las dos duraciones para esta candidata y alcance sintético. No acredita
upstream, OBS, navegador, Internet, cloudflared, operación continua, otra revisión
ni ausencia de fugas a cualquier duración. No se reinició ningún contenedor, no
se ejecutaron plataformas reales y no hubo despliegue. El resto de #4/#55 sigue
abierto. Rollback documental por revert; informes originales permanecen conservados.

Validación del cierre documental: analizador ejecutado sobre los dos informes;
resumen de 24 h reproducido exactamente. Tres informes alterados de prueba
(entrega incompleta, duración insuficiente y minuto ausente) rechazados.
Estática específica, secrets y diff-check PASS. Auto Review Codex del bundle:
exit 0 sin hallazgos accionables; revisión estática, sin ejecutar cargas.
CI remoto de esta PR pendiente. El temporizador antiguo está desactivado;
no se crea otro para este resultado ya disponible.
