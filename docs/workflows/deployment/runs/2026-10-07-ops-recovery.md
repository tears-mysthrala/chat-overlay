# Recuperación y mantenimiento — Refs #40, #39, #62

Autorización: continuar ARCH06, backup externo/restauración y mantenimiento;
destino Google Drive existente aprobado explícitamente. Sin servicios de pago.
Rama chore/40-backup-maintenance desde fb016d8, worktree chat-overlay-ops-40.

Backup propuesto: OpenSSL CMS AuthEnvelopedData AES-256-GCM con certificado
RSA del operador, sin nueva dependencia de producción. Clave privada solo en
este PC con ACL limitada; Benten recibe únicamente el certificado público.
App y coordinador detenidos durante dump y snapshot de medios/SQLite, reinicio
mediante trap. Se incluyen roles, base, TLS/configuración y medios. Solo el
ciphertext se copia a Drive. La restauración valida primero el resultado de
descifrado y los checksums; nunca extrae salida antes de autenticarla.

Pendiente: pruebas criptográficas negativas, backup real, descarga/restore
aislado, sincronización efectiva Drive, revisión/CI/merge. ARCH06 exige separar
la superficie pública del proceso con acceso a secretos; RLS no basta. No se
declara resuelto por el backup. El mantenimiento no eliminará tombstones sin
demostrar que las escrituras tardías y trabajos pendientes siguen rechazados.

## Ejecutado

- OpenSSL disponible: Windows3.6.1 y Benten3.5.7. CMS AES-256-GCM roundtrip,
  manipulación del tag y clave RSA incorrecta: PASS. Clave3072 en directorio
  local privado fuera de Drive, ACL solo operador/SYSTEM; certificado público
  enviado a Benten. No nueva dependencia de producción.
- Backup real externo-JoKPhEWn generado con app/coordinador detenidos brevemente;
  trap reanudó ambos. Readiness y coordinador active PASS. No cambio de datos.
- Ciphertext635462 bytes, SHA256
  cda1e997892f1940250959b162e7f7850d4dfed9a280f1a0817deceb4c5b1fe2.
  Copia a `G:/My Drive/Chat Overlay/Backups/2026-10-07-JoKPhEWn.cms`
  y comparación hash PASS.
- Drive remoto: carpeta/archivo encontrados mediante listado del conector;
  archivo1mirNaSsscGCsiI9TpYErJU27YiUqAqot, tamaño635462, shared=false.
  Búsqueda por nombre no devolvía el binario; listado de carpeta sí confirmó
  sincronización. Descarga materializada del conector recibió HTTP403: lectura
  independiente de esos bytes remotos NOT TESTED; no se buscaron credenciales
  alternativas. Restore utiliza la copia verificada en el volumen Drive local.
- Descifrado autenticado y manifiesto del bundle PASS. PostgreSQL real en Docker
  network=none/tmpfs, sin puertos ni volúmenes de producción: restore PASS,
  conteos1perfil/2cuentas/2objetos, FORCE RLS en3tablas y SQLite/media hashes PASS.
- Descifrado de ambas cuentas con su AAD y clave restaurada en runtime43ed8a7a,
  sin red/rootfsreadonly/capsALLdrop: PASS. No tokens en salida.
  Primer intento usaba JSON.decode! inexistente; corregido a decode con errores
  genéricos. No conexiones/reautenticación upstream durante la prueba.
- No backup periódico instalado aún; copia manual puntual. Clave única local:
  su custodia redundante fuera de este PC requiere un destino separado.
  Esta unidad no cierra #40 completo ni ARCH06. Revisión/CI/merge pendientes.

Compactación local preparada, no aplicada a producción: requiere app/coordinador
detenidos y ledger PostgreSQL tomado después de detenerlos. Solo acepta objetos
locales activos públicos; conserva bytes y verifica hashes/inventario. Rechaza
trabajo incierto/cancelado/sin resultado, cuarentena no vacía o discrepancias.
Elimina tombstones sin archivos y journal de jobs resueltos mediante transacción
SQLite de ambas bases en modo DELETE; no expone endpoint HTTP ni aplica a R2.
3regresiones Linux PASS: preservación de activos, rollback ante incertidumbre y
rechazo de writers no detenidos/ledger pendiente. Aplicación real pendiente de
revisión y CI. Para trabajo ambiguo se mantiene el bloqueo y conciliación manual.

ARCH06: propuesta concreta ADR0008, sin nuevas dependencias; custodio privado y
frente público sin clave maestra/DB/OAuth. El protocolo privado cerrado necesita
decisión explícita antes de implementar. No se cambia la arquitectura en esta PR.

Codex cloud sobre55048d9 detectó P1: un operador Linux distinto de UID65532
no permite al runtime atravesar el bind mount del directorio0700. Confirmado;
la prueba anterior en Docker Desktop no acreditaba esos permisos Linux. Se
elimina el montaje completo y se envían únicamente metadatos de cuentas cifradas
por stdin al proceso no root. El directorio privado no cambia permisos.
Restore real con stdin: DB/conteos/RLS/medios/descifrado PASS; 8tests scripts PASS.

CodeRabbit196a12d: confirmado residuo en claro del backup en Benten. El trap
ahora retira los siete temporales propios en éxito/fallo y conserva ciphertext
solo tras cifrado completo. Diez tests Linux PASS, incluidos éxito y fallo de
cifrado con reanudación y limpieza. La copia real ya creada se verificó por
SHA256 y sus temporales en Benten se retiraron; backup.cms conservado y readiness
PASS. No se borraron datos activos ni copias cifradas. Comentarios adicionales:
ADR anclado a rutas reales de supervisor/configuración/lectura de secretos;
manifiestos malformados reciben error uniforme, sin ampliar formatos admitidos.
