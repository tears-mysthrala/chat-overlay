# Candidata local F2 — 2026-10-07

## Actualización: revisión oficial OpenAI completada

Tras autorización expresa del usuario, se sustituyó la skill personal autoreview
por OpenAI Codex Security `security-diff-scan`. Scan
`ca29daab-434e-4c62-955c-afebd4fe2a85`, rango inmutable base main -> `aab4572`.
Preflight ready; padre y trabajadores `gpt-6.1-sol`, sin modelos superiores.
44 entradas oficiales revisadas (23 auth/RLS, 12 media, 9 tooling), más
Dockerfiles, parches CPython y pruebas de apoyo. Cero hallazgos nuevos reportables;
cobertura marcada parcial por seguimientos pendientes. Informe sellado en el
estado local del plugin, colección `chat-overlay-f2-candidate`, revisión `aab4572`,
directorio `aab45728d0087b8513bf25ef0354cb1fdb3a3c9f_20261007T083616Z_e8fv5_so/report.md`.

La duda sobre CVE-2026-12345 se resolvió con registro CVE oficial PUBLISHED y
checksum del parche upstream coincidente. No resuelve los matches APK del scanner.
Demo tras proxy loopback conserva una excepción de autorización preexistente;
su configuración pública debe evaluarse antes de distribuir. Postgrex transmite
verify_peer/CA/SNI a OTP; la opción ssl_opts está deprecada y no se probó TLS real.
Los contadores del plugin proceden de tres rollouts, no de un coste facturado
aislado: totalTokens 4831047, inputTokens 4816855, cachedInputTokens 4605696.
La revisión no ejecutó de nuevo las suites ni acredita producción.

Este resultado sustituye el bloqueo de revisión descrito históricamente abajo.
Siguen pendientes seis matches, cobertura CVE del FFmpeg git, gates operativos,
CI y aprobación humana. No se aplicó VEX ni se hizo push/merge/despliegue.

Estado: implementación integrada y validación local; cierre de seguridad pendiente.
Rama `security/55-f2-local-candidate`, issue #55. Base main
`1bc715c875ebe61a63b533705b88ae9c066cf3c7`. Sin push, PR, merge ni despliegue.
La autorización cubre PostgreSQL/Postgrex/RLS y cuarentena local ADR0005.

## Revisión reproducible

Unidades originales: OAuth `d261ebf`, PostgreSQL `e9349a9`, cuarentena
`60aa5bacabfa5621c7889145223f667996a4ee8c`; cherry-picks en esta rama.
Imagen de producto/validación integrada:
`sha256:0116bb77cfc5eb53473c1a240b7ce1c4557884aa293c43c1249747f5ddca19a2`.
Las modificaciones posteriores del fixture/proxy de navegador se probaron montadas;
no están incluidas en esa imagen. No cambian el código de producto.

- Suite general: 274 PASS, semilla 0 serial y 424242 concurrente.
- PostgreSQL real local: 26 PASS por semilla; boot, escritura y reinicio PASS.
  Incluye nueva regresión media pending/ready/active bajo RequestScope/RLS,
  aislamiento de otro perfil y recarga durable. Recursos PostgreSQL retirados.
- `python scripts/check_test_report.py output/tests/exunit-0.json output/tests/exunit-424242.json`
  y equivalente `output/postgres/postgres-{0,424242}.json`: dos ejecuciones
  completas por suite, sin failures, skips ni exclusions.
- Decoder real: 10 PASS; coordinador con decoder real/storage sintético: 8 PASS.
  Imagen `sha256:89432cb33a13415bb42558259ccf1ea299118d0163547555f8644ae11b0f8bff`.
- Backports CPython: ocho regresiones PASS, UID65532, sin skips.
- Static checks y Gitleaks: cero hallazgos en la validación integrada anterior.
  Sintaxis JS, compilación propia warnings-as-errors e inventario de licencias PASS.
  Postgrex presenta una advertencia de API deprecada al compilar la dependencia;
  no se acredita una compilación de todas las dependencias sin advertencias.

## Navegador

T3 preview nativo Chromium, escritorio 1280x800, `scripts/browser_checks.js`:
login/verify/logged-out PASS. Perfil alice único, bob POST403, HttpOnly,
subidas sin permiso deshabilitadas, recuperación de URL HTTP inválida,
capability regenerada/revocada, SSE autorizado, ausencia de overflow, logout
y borrado de copias sessionStorage comprobados.

Servidor demo con OAuth simulado, credenciales sintéticas y localhost:4143.
Proxy Node sustituye XFP/XFF y fixture confía exclusivamente en el gateway
inspeccionado. HTTPS es sintético: no verifica TLS ni proveedores reales.
La red Docker interna publicada produjo 502 en Windows Docker Desktop; se
repitió con red bridge propia y puerto publicado solo en 127.0.0.1:4144.
Un primer montaje apuntaba /app en lugar de /build: se corrigió antes del PASS.
El CI Linux conserva su red interna y conexión directa a IP del fixture;
no se ejecutó GitHub Actions ni la variante móvil en esta continuación.
No se probó la subida positiva completa desde navegador contra R2 real.
`mix format --check-formatted scripts/browser_fixture.exs`, Node syntax y
`wsl bash -n scripts/ci_browser.sh` PASS. Bash no estaba en la imagen de
validación; se comprobó con WSL. Fixture, red y proceso proxy propios retirados.

## Gate del decoder: seis matches activos

No hay VEX ni suppressions nuevos aplicados. El escáner sigue fallando.

| Identificador | Componentes | Evidencia / decisión pendiente |
| --- | --- | --- |
| CVE-2026-87910 | python3 | Backport oficial tarfile a4919937, regresión ejecutada; APK conserva versión original. Falta declaración revisada de componente parcheado. |
| CVE-2025-15367 | python3 | Backport oficial poplib b234a2b6, regresiones ejecutadas; mismo límite del inventario APK. |
| CVE-2026-12345 | python3 | Backport tempfile/shutil 363aec1f, regresiones ejecutadas; PR upstream 158430 aún abierto al revisar. No afirmar release oficial corregida. |
| CVE-2025-60876 | busybox, busybox-binsh, ssl_client | Camino wget de inyección CR/LF; decoder sin red y no invoca wget. Falta evaluación/declaración específica del decoder por responsable humano. |

Parches completos y SHA256SUMS bajo `vendor/media/python`; inventario de
archivos runtime en `/usr/share/media-components.json` de la imagen.
FFmpeg mínimo upstream commit `e5a08f7c0e45e6d278a394ef19c97f0b8ad3ed45`,
versión reportada `8.0.git`: el fix PNG b506faf está incluido. Componentes
no usados se eliminaron; eso no demuestra que todas las CVE originales estén
corregidas. La cobertura automática de CVE para ese commit sin release es
limitada y sigue necesitando revisión. La SBOM conserva FFmpeg explícitamente.
No trasladar el VEX del runtime BEAM al decoder ni aceptar alertas por silencio.

## Revisión y límites

Sol hizo revisión local acotada de integración sin conflicto concreto nuevo;
no constituye auditoría global ni aprobación humana. Hallazgo PUT público
ambiguo corregido: reserva persiste mediante journal uncertain y tombstone
durables hasta reconciliación/sellado, incluso tras retry/restart.

La revisión estructurada externa fue rechazada por auto_review: enviaría
potencialmente código privado a chatgpt.com sin autorización explícita de
exposición. No se reintentó. La skill autoreview exige el helper estructurado
antes del cierre; falta permiso para esa transferencia o una alternativa
estructurada local que no exponga el código.

Pendientes: resolución verificable de las seis alertas/cobertura FFmpeg,
revisión estructurada, CI, mobile/browser upload E2E, OAuth/TLS/R2 reales y
gates humanos/ARCH-06. Un BEAM con cache/pools no aísla un BEAM comprometido.
Sealed cleanup requiere parar firmantes y drenar PUT privados/públicos: las
pruebas sintéticas no acreditan esa operación en R2. No cerrar #42/#49/#51/F2.
