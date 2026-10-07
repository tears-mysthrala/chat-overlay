# Validación local de cuarentena — Refs #49

Solo entorno sintético; no cuentas, publicación, merge ni despliegue.
Comprobar contrato/ADR0005, rama/worktree y cambios antes de continuar.

1. `docker build -f Dockerfile.media-validator -t chat-overlay:media-validator .`.
   Verifica fuente/parches y ejecuta ocho regresiones CPython sin privilegios.
2. Fijar `MEDIA_VALIDATOR_IMAGE=sha256:<ID>`; ejecutar
   `python scripts/test_media_sandbox.py -q` y
   `python scripts/test_media_coordinator.py -q`. Storage sintético; decoder real.
3. `python scripts/audit_image.py sha256:<ID> --decoder`: SBOM con FFmpeg propio
   y archivos Python. No usar el VEX de BEAM para decoder ni inferir cobertura
   CVE de release para un commit git.
4. Imagen BEAM validation, `scripts/ci_tests.sh` sin red y ambos reportes mediante
   `scripts/check_test_report.py`. Static checks, JS y Gitleaks local.
5. Revisión scoped independiente, fixes/regresiones y commit local `Refs #49`.
6. Candidata separada con OAuth/PostgreSQL: comprobar autorización, persistencia
   y ledger sobre su misma revisión antes de pedir aprobación de entrega.

No declarar F2 cerrado sin revisión humana, CI remota, R2/OBS y gates operativos.
Sellado exige detener emisión, revocar firmante y drenar escrituras antes del flag.
Rollback conserva ledger/journal y deshabilita subidas.
