# Borrado confirmado con TOTP — 2026-10-11

Refs #48, #50, #55. Rama test/48-deletion-acceptance; base de continuación f5213e1.
Se sustituye la denegación provisional por TOTP estándar separado de OAuth,
provisionado offline por el operador y vinculado a perfil/identidad. Decisiones,
amenazas y límites en ADR 0009. No se provisionan factores reales ni se despliega.

Implementación: UI de confirmación, header acotado, protocolo mTLS cerrado,
revalidación de sesión y consumo único dentro del escritor; rate limit 5/300 s,
rechazo del intervalo de arranque y configuración privada prohibida en frontend.
El aprovisionamiento verifica un código antes de producir el archivo activo.

Validación ejecutada durante desarrollo: 39 pruebas de sesión/custodio/TOTP PASS;
12 de TOTP y borrado integrado PASS; después 25 de mTLS real, borrado y TOTP PASS.
Cubren A/B, revocación en cola, persistencia fallida, replay, rate limit, reinicio,
retiro/reload de inventario y reintento remoto sellado. Los fixtures son sintéticos.
NimbleTOTP requirió pin explícito de binding de bitstring para Elixir 1.20;
adaptación de fuente verificada por hash y vectores RFC 6238 PASS.

Hex encontró Decimal 3.1.1 vulnerable a CVE-2026-97853 (Medium). Actualizado a
3.2.0; auditoría Hex sin avisos ni paquetes retirados. No se atribuye explotación
a la aplicación ni se extrapola el resultado al sistema operativo de la imagen.

Cierre de validación local (datos sintéticos):

- `sh scripts/ci_tests.sh`: 347 PASS con seed 0 serial y 347 PASS con
  seed 424242 concurrente; cero fallos, excluidos u omitidos. Validador de informes PASS.
- `ci_postgres.sh`: 26 PASS por cada seed 0/424242, con PostgreSQL 18.6 real,
  roles restringidos y reinicio/persistencia del producto PASS. Incluye Decimal 3.2.0.
- Build/format/compile con warnings como errores; inventario de 14 licencias PASS.
  Imagen validation `sha256:1e63c416426760bef76663d23075eee9268c2afbf759fad7182df56dacb2a01a`.
- Release `sha256:007e79d7a90f8a727e77b2ec4b98444ec06cdece55350bd1f6b964de4c6c232d`:
  smoke e aislamiento frontend/custodio PASS; SBOM CycloneDX válido, 296 componentes.
  Escaneo: cero hallazgos activos y cuatro coincidencias cubiertas por las dos
  declaraciones VEX vigentes. Esto no es una firma ni ausencia absoluta de vulnerabilidades.
- Preview nativo T3 sobre fixture aislado: diálogo a 1280 y 390 px, foco inicial,
  Escape/restauración de foco, formato inválido sin envío y ausencia de desbordamiento.
  Borrado final a 390 px: vuelve a login, oculta panel/banner, elimina copia OBS,
  API de perfiles 401 y documento persistente conserva únicamente Bob.
- La comprobación visual detectó estado de panel retenido tras borrar. Se corrigió
  recargando tras éxito, revocando la cookie y revalidando la vinculación al listar
  perfiles. 43 pruebas focalizadas y la suite completa anterior cubren el delta final.
- Estática específica: cero hallazgos dentro de sus reglas. JS sintácticamente válido,
  secrets sin fugas y diff-check PASS.
- Auto Review Codex del bundle final: exit 0 sin hallazgos accionables. Revisión
  estática de confianza limitada: falló su shell, por lo que no pudo inspeccionar
  contexto adicional ni ejecutar pruebas. No se presenta como aprobación humana.

[Informes conservados en Git](../evidence/2026-10-11-deletion-totp/).
Las comprobaciones de navegador usan TLS simulado en localhost; mTLS real se
comprueba en ExUnit y en el smoke separado. No hay nueva prueba en OBS, OAuth real,
factor de usuario provisionado ni despliegue. CI de este delta pendiente de push.
#48 conserva conciliación de inventario heredado y vista operativa de limpieza
pendiente como siguiente unidad. La PR entrega autorización y aceptación integrada,
no se declara cierre total del issue. Rollback por revert; no migra datos de usuario.
