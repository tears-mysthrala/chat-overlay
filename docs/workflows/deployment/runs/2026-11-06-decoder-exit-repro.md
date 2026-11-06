# Causa de `validator_exited` intermitente — 2026-11-06

Refs #49. Base `c016c06`, dependiente de la rama `fix/46-ci-build-recovery`. Sin cambios de
producción, imagen, launcher, VEX ni aprobaciones. Sigue a
[la corrección del 09-10-2026](2026-10-09-decoder-log-race.md), que no pudo atribuir el fallo.

## Causa

Carrera en el launcher anterior a `95d1539`: leía los logs vacíos, y si al comprobar el estado el
decoder ya había terminado, declaraba `validator_exited` sin volver a leer. Un rechazo por
animación sale antes de lanzar FFprobe, así que el decoder termina muy deprisa. No es un defecto
del decoder ni un OOM. `95d1539` ya lo corrige; esta unidad no cambia el launcher.

## Reproducción

Launcher de `41e07c2`, el commit del run 37889170966, frente al actual. Rechazos reales de APNG y
WebP animado por alternancia, en serie y en contenedores con los límites del launcher. Antes de
retirar cada contenedor se registró su estado. Docker 29.9.2, VM de ~3,5 GiB. "Carga" son 6 procesos
ocupando CPU. "Retardo" son 0,3 s inyectados antes de consultar el estado.

| Launcher | Imagen | Condición | Rechazos correctos | `validator_exited` |
| --- | --- | --- | --- | --- |
| `41e07c2` | histórica | natural | 225/300 | **75** |
| `41e07c2` | histórica | carga | 136/150 | **14** |
| `41e07c2` | histórica | retardo | 3/30 | **27** |
| actual | histórica | natural | 300/300 | 0 |
| actual | histórica | carga | 150/150 | 0 |
| actual | histórica | retardo | 30/30 | 0 |
| actual | candidata | natural | 300/300 | 0 |
| actual | candidata | carga | 150/150 | 0 |

En los fallos registrados, hasta 25 por tanda, el contenedor tenía `ExitCode` 1, `OOMKilled` false
y el rechazo correcto en sus logs. El registro de comandos del launcher actual no distingue la
relectura tras un contenedor ya terminado de una espera normal, así que no mide cuántas veces la
relectura recupera el informe. Una primera tanda se descartó porque el
arnés ejecutaba fases a la vez; estas cifras son de la repetición en serie, sin solapes.

## Regresión

`test_sandbox_exit.py` ya era determinista y falla con el launcher antiguo. Se añade a
`test_media_sandbox.py` una prueba con 20 rechazos reales: con el launcher antiguo falló en 5 de 5
ejecuciones, y pasa con el actual en ambas imágenes. Con la candidata pasan las cinco suites del
decoder; con la histórica, en esta unidad, solo `test_media_sandbox.py`.

## Límites

- El job original no conserva el estado del contenedor, que se retiró. Coinciden prueba, mensaje y
  código, pero la atribución de ese fallo concreto es una inferencia sólida, no una observación.
- La tasa es de este host: el runner de GitHub no se repitió. CI remota de esta rama pendiente.
- El fallo observado era de la imagen construida entonces; la receta ya no se puede reconstruir.
  Se usó el artefacto histórico aprobado.
- Excepciones no capturadas con salidas falsas de FFprobe o FFmpeg (#50) también acaban en
  `validator_exited`, pero es otra causa: fallan cerradas y no se han observado con las herramientas reales.
  No se cambian aquí.
- #49 sigue abierto por el resto de su aceptación global. Rollback: revert.
