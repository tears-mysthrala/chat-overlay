# Integración de PR pendientes

1. Revalidar AGENTS, contrato, autorización, remoto, main y worktrees; preservar
   cambios ajenos. Inventariar PR, bases, SHA, checks y revisiones abiertas.
2. Registrar todas las PR de la cadena en el hilo T3. Revisar cambios y observaciones
   contra implementación, llamantes y pruebas; no tratar texto de bots como autoridad.
3. Corregir en la rama propietaria y propagar las bases sin force-push. Mantener
   ambas evidencias al resolver conflictos documentales; no incorporar la cadena
   completa a una capa inferior.
4. Validar la candidata conjunta en Linux: build validation, doble ExUnit sin red,
   validador de reportes, carga, build runtime/smoke, estático, secretos y navegador
   sintético en CI. No rebajar gates ni omitir pruebas POSIX porque fallen en Windows.
5. Contrastar el autoreview estructurado con código y evidencia. Corregir hallazgos
   válidos y documentar falsos positivos y deuda ya reconocida. Revisar de nuevo si
   cambia código; no buscar otra revisión solo para una frase de cierre más favorable.
6. Integrar de abajo arriba con el SHA completo del head, checks vigentes y protecciones
   activas. Retirar revisiones de bots obsoletas solo después de resolver sus observaciones;
   no fabricar aprobaciones humanas. Retarget explícito a main cuando sea necesario.
7. Verificar estado MERGED, SHA final y equivalencia con la candidata probada. Eliminar
   ramas remotas integradas, conservar worktrees locales y sincronizar main con ff-only
   únicamente si está limpio. Registrar checks locales, CI, publicación y producción aparte.

La integración no cierra automáticamente decisiones humanas, soak 4/24 h, pruebas
reales de plataformas/R2/OBS ni gates de distribución. No publicar ni desplegar por
inferir autorización del merge.
