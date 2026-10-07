# VEX decoder aprobado — Refs #55

Kalista aprobó con «Apruebo la propuesta» las cuatro declaraciones preparadas
en el seguimiento F2: tres fixed Python por backport y una not_affected Busybox
para la imagen y configuración concretas. Se conservan los borradores históricos;
las copias `.approved.json` registran autorización, responsable y revisión
debida 2026-10-21. No constituyen una firma criptográfica.

`scripts/decoder_vex.py` verifica digest, arquitectura, hashes del repositorio,
hashes reales de ocho archivos dentro de la imagen, estado de aprobación y
caducidad antes de entregar VEX al escáner. Lectura offline con UID65532,
readonly, caps drop, no-new-privileges y límites de recursos. Cualquier fallo
detiene la auditoría. Un rebuild distinto no hereda esta aprobación.

El informe sin filtrar se conserva como `output/audit/decoder/vulnerabilities.raw.json`;
el informe con disposiciones usa `vulnerabilities.json`. Ambos quedan en el mismo
directorio de evidencia de imagen/SBOM/VEX. No se elimina el binario Busybox ni se
afirma que su wget esté corregido. La ausencia de camino ejecutable depende del
launcher y flujo aprobados, no de usos arbitrarios de la imagen.

Pruebas: caso válido y seis controles negativos (aprobación, imagen,
arquitectura, runtime, fuente, caducidad) PASS en Python normal y optimizado.
Cinco pruebas del validador de evidencia PASS; estáticos cero hallazgos;
`git diff --check` PASS. Las mismas pruebas nuevas se añaden a CI; CI remota
no ejecutada. Escaneo real exit 0: CycloneDX 1.7 válido, 1437 componentes;
seis coincidencias originales conservadas, exactamente seis cubiertas por VEX
y cero activas. Se verificó igualdad de pares CVE/PURL entre el informe bruto
y `ignoredMatches`, sin pérdida de hallazgos. Escaneo de secretos PASS.

Persisten cobertura incompleta de todos los CVE FFmpeg git, validación R2/OAuth
real/TLS/OBS y CI remota. No cierre total F2 ni publicación, merge o despliegue.
