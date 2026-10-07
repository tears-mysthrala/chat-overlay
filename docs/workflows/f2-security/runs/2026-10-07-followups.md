# Seguimiento F2 — 2026-10-07 — issue #55

## Resultado local

Se corrigió la excepción demo: un peer loopback configurado como proxy ya no
concede permisos anónimos. Tampoco un peer ausente con Host localhost.
La decisión compartida protege sesiones, perfiles, media y OAuth; conserva
el acceso directo local IPv4/IPv6 y los permisos del propietario autenticado.
Configurar los peers proxy sigue siendo responsabilidad del despliegue.

La regresión previa reprodujo dos fallos entre 23 pruebas. La candidata pasa
52 pruebas enfocadas, 278 generales en semillas 0 y 424242 y 26 PostgreSQL
en ambas semillas, con informes completos sin omisiones. PostgreSQL verificó
también persistencia tras reinicio. Format, compilación del producto con
warnings-as-errors, inventario/licencias, chequeos estáticos y secretos pasan.
Permanece visible una advertencia xref deprecada en la dependencia Postgrex.
Un investigador Sol y un revisor nuevo Sol trabajaron en solo lectura:
el primero confirmó el fallo y el segundo no identificó un bypass o regresión
concreta en la corrección. Su revisión fue estática, no ejecutó pruebas.

Imagen de validación del producto:
`sha256:36e654d0ab5c14d8b16558b9f766ce04bd7229b1f853f6343a6b4737069d3019`.
La ampliación posterior de assertions Python no cambia el runtime del producto.

## Decoder: evidencia y decisión pendiente

Imagen: `sha256:89432cb33a13415bb42558259ccf1ea299118d0163547555f8644ae11b0f8bff`.
Diez pruebas del sandbox y ocho del coordinador pasan. Se comprueban además
imagen exacta, entrypoint/argv, dispositivos, privilegios, límites y ausencia
de variables de credenciales. Los recursos de prueba PostgreSQL se eliminaron.

El escaneo actualizado devuelve **seis coincidencias, sin supresiones**, exit 1.
CycloneDX 1.7 válido, 1437 componentes. Tres coincidencias Python corresponden
a backports con pruebas upstream y hashes de módulos verificados. Las otras
tres representan CVE-2025-60876 en Busybox, busybox-binsh y ssl_client: el applet
wget vulnerable sigue presente. El camino autorizado del decoder no lo invoca;
esta conclusión no cubre usos genéricos de la imagen ni cambios del launcher.

Se prepara [VEX propuesto](../../../security/vex-decoder.proposed.json) y
[evidencia vinculada](../../../security/decoder-evidence.proposed.json), con
responsable Kalista, issue #55 y revisión debida 2026-10-21. Los JSON, hashes
del repositorio y correspondencia exacta con las seis coincidencias se validaron.
**No aprobado ni aplicado**. Antes de activar cualquier declaración, exigir
validación del digest de imagen y hashes de fuente/runtime; PURL solo no basta.
SUP-07 exige responsable humano, motivo, compensación, caducidad e issue para
excepciones. No se ha modificado el escáner para ocultar resultados.

## Límites restantes

No se demuestra cobertura completa de todos los CVE de FFmpeg mediante su
versión git. Tampoco hay nueva validación CI, proveedor OAuth real, R2, TLS
externo, OBS o despliegue. La revisión oficial anterior queda sellada y no se
reescribe; este registro documenta cambios y evidencia posteriores.
Main no se modifica; no se publica, empuja ni despliega esta candidata.
