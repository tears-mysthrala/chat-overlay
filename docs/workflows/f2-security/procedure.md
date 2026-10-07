# Procedimiento local

1. Verificar contrato, issue real, rama y worktree; preservar modificaciones ajenas.
2. Leer el registro anterior y los resultados terminales de tareas delegadas.
   Un fallo por cuota no cuenta como revisión ni como validación.
3. Trabajar en una unidad y probar regresiones relevantes. Fijar una imagen de
   validación antes de la suite completa; no editar archivos montados durante ella.
4. Ejecutar `scripts/ci_tests.sh` sin red y comprobar ambos reportes con
   `scripts/check_test_report.py`. Conservar errores y resultados con su revisión.
5. Ejecutar revisión estructurada antes de commit/entrega; resolver hallazgos
   aceptados y repetir únicamente los checks afectados.
6. Para ADR0005 A/B, verificar DB/decoder reales locales y luego la integración.
   Conservar límites pendientes; no convertir fixtures en acreditación de producción.
7. No hacer merge, publicar ni desplegar sin la autorización correspondiente.
   Hallazgos sensibles siguen DEV-09, fuera del informe público.
