# Validación de almacenamiento PostgreSQL #51

1. Verificar ruta/rama limpia o cambios propios, AGENTS, contrato, ADR y issue real.
2. Construir validation con versiones/digests fijados; Hex audit e inventario de
   licencias son gates del build. Formatear con el mismo Elixir Linux del builder.
3. Ejecutar `scripts/test_postgres_local.ps1`: proyecto Docker sintético único,
   owner offline y runtime/bootstrap separados, suites DB y arranque/reinicio real.
4. Ejecutar `scripts/ci_tests.sh` sin red para las dos suites regulares completas;
   comprobar ambos pares de reportes con `scripts/check_test_report.py`.
5. Estático, secretos y smoke de release proporcionales. Registrar versiones,
   comandos, resultados, fallos y recursos, sin datos privados ni credenciales.
6. Autoreview estructurado local antes de commit. Contrastar y corregir hallazgos;
   tras cambiar código repetir pruebas afectadas y revisión. No paneles anidados.
7. Commit local con Refs #51 únicamente tras validación/revisión. Mantener #51
   abierta y distinguir local, CI, publicación y producción; sin push ni merge.
