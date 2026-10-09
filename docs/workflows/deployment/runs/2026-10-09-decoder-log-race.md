# Rechazo del decoder durante polling — 09-10-2026

Refs #49. CI de PR #72, intento1 de run37889170966, recibió
`validator_exited` en vez del rechazo de animación esperado; intento2 pasó.
El código permite leer logs vacíos, después observar el contenedor terminado
y perder el informe publicado entre ambas consultas.

Se añade una lectura final de logs cuando el contenedor ya no está ejecutándose.
El informe sigue validándose por el mismo camino. Salida sin informe, JSON
inválido, rechazo, timeout y limpieza continúan produciendo errores. No cambia
la imagen del decoder ni sus límites o formatos permitidos.

Regresión determinista reproduce la secuencia y comprueba rechazo recibido,
salida sin informe y JSON mal formado. Tres PASS. Suite real sobre imagen local
de decoder existente: diez PASS. Suite scripts/tests: quince PASS en
python:3.13-alpine sin red; intento Windows tuvo cuatro errores por falta de sh,
resueltos ejecutando la suite en Linux, sin modificar sus pruebas.

Estática específica: cero hallazgos (reglas limitadas). Escáner de secretos:
cero fugas. Diff check PASS. Auto Review Codex local: exit0, sin hallazgos
accionables; revisión limitada al bundle. La regresión acredita la carrera,
pero no conserva una traza del contenedor fallido de CI para atribuirle con
certeza exclusiva ese fallo histórico.

La carga de24 h permanece en su contenedor independiente. Esta corrección del
lanzador no modifica la imagen BEAM usada por esa carga ni producción.
Rollback: revertir el parche del lanzador y su regresión. #49 permanece abierto
para el resto de su aceptación.
