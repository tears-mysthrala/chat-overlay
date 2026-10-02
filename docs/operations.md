# Operación local y preparación de publicación

## Arranque, parada y actualización

Usar Compose para la demo local o construir `docker build -t chat-overlay:<revision> .`. No publicar el puerto en interfaces externas antes de superar los gates. La demo puede montar configuración de solo lectura; F2 con mutaciones necesita una ruta privada escribible y no debe confirmar cambios si falla la persistencia (#56). No hay volumen de historial persistente de chats. `/health/live` confirma listener y `/health/ready` comprueba stores: no certifica conectividad upstream.

La imagen corre como UID/GID 65532. Compose elimina capacidades, impide nuevos privilegios, limita CPU a 2, memoria a 1 GiB y PID a 128, monta raíz de solo lectura y `/tmp` acotado. Desactiva distribución Erlang y vuelcos de crash a disco. La VM tiene dos schedulers y límites explícitos de procesos/puertos. No montar socket Docker, directorios del host o credenciales de otras aplicaciones.

Para actualizar: conservar configuración y referencias secretas fuera de Git, construir y probar un nuevo digest, comparar SBOM/avisos, detener la instancia anterior y arrancar la nueva con los mismos límites. Rollback: aplicar el [procedimiento de recuperación](recovery.md); no restaurar una configuración antigua sobre mutaciones posteriores. Rotar tokens cambiando el entorno o regenerando en caliente desde el panel; no imprimirlos ni pasarlos como argumentos de CLI.

## Acceso, Capability Tokens y observabilidad

El operador debe mantener TLS, proxy sin buffering SSE, segmentación y límites de conexión/rate a la entrada. Las IP reenviadas no son identidad. No registrar contenido de chat, credenciales, cookies ni URLs con capabilities/firmas, tampoco sus prefijos; los estados públicos omiten detalles de credenciales y errores upstream. Los mensajes de chat se retienen hasta 30 minutos/100 por perfil en RAM.

- **Capability Tokens para OBS**: Las URLs de overlay `/overlay/:handle?token=<token>` y de eventos `/events/:handle?token=<token>&view=overlay` exigen el capability cuando el perfil lo tiene configurado; la compatibilidad con perfiles sin hash no implica privacidad. El valor generado tiene 32 bytes URL-safe.
- **Revocación en caliente**: Desde el Panel de Creador (`/`) o mediante `POST /api/profiles/:handle/token/regenerate`, el token se regenera de forma atómica. El token previo queda revocado de inmediato en memoria y disco; cualquier nueva conexión, reconexión o recarga de la fuente en OBS con el token revocado es rechazada con 401 Unauthorized (mostrando la pantalla de aviso amigable en el navegador), sin interrumpir la ingestión de chat de las plataformas ni reiniciar el nodo.
- **Panel de Creador**: Accesible en `/`. Proporciona gestión de tokens con aviso previo de revocación, botón de copia rápida, configuración de alertas multimedia y reproductor de prueba de sonido integrado.

## Módulo Multimedia (Cloudflare R2 y URLs Externas)

- **Variables de entorno R2 (obligatorias si se pretende usar el módulo; no activarlo antes de resolver #49)**:
  - `R2_ENDPOINT`: Endpoint S3 compatible de Cloudflare R2 (p. ej. `https://<account_id>.r2.cloudflarestorage.com`).
  - `R2_BUCKET`: Nombre del bucket de Cloudflare R2.
  - `R2_ACCESS_KEY_ID`: Identificador de clave de acceso SigV4.
  - `R2_SECRET_ACCESS_KEY`: Clave de acceso secreta SigV4.
  - `R2_PUBLIC_CDN`: Dominio base público del bucket o CDN (p. ej. `https://media.mysthrala.com`).
- **Arquitectura Zero Server Footprint**: El servidor Elixir genera URLs prefirmadas PUT compatibles con AWS SigV4 de forma nativa en OTP (`POST /api/media/presign`). El cliente sube el archivo multimedia directamente a Cloudflare R2 sin consumir ancho de banda de red ni memoria en el backend.
- **Límites y restricciones de seguridad**:
  - Audios: `.mp3`, `.ogg`, `.wav`, `.webm` (máximo 2 MB por archivo).
  - Imágenes/emojis: `.webp`, `.png`, `.gif` (máximo 512 KB por archivo).
  - **Prohibición estricta de `.svg`**: Rechazado deterministamente por extensión declarada; no prueba el formato real ni neutraliza por sí sola XSS.
  - Candidata #57: cuota por perfil (10 MiB), incluidos activos, reservas y limpieza pendiente. Ver [inventario y límites](media-storage.md).
  - URLs externas: se comprueba HTTPS/extensión y DNS al guardarlas. El navegador resuelve de nuevo; esa comprobación no fija su destino futuro ni inspecciona bytes.

## Vulnerabilidades y gates

[SECURITY.md](../SECURITY.md) identifica el canal privado real y a Kalista como responsable. Conservar versión/digest, alcance y evidencia sin secretos; reproducir en aislamiento, corregir y repetir pruebas. El responsable decide distribución, comunicaciones y cualquier obligación de notificación; verificar normativa vigente al activar un incidente. No hacer notificaciones automáticas a terceros.

Registro histórico de #21 (30-09-2026; no repetido sobre la candidata actual): gates de seguridad de imagen y SBOM validados en verde (Grype 0 vulnerabilidades, OpenVEX aprobado por Kalista, Hex audit limpio), ExUnit 110/110 pruebas PASS, carga sintética REL-08 (p95 49 ms; la prueba extendida de 24 horas permanece pendiente antes de una distribución pública general, documentada en [verificación](verification.md)), validación en vivo de Twitch y YouTube, validación en vivo automatizada en OBS Studio 32.2.2 en los 5 estados de capability tokens y canal alfa transparente, y CSP estricta autorizando hash de estilos de OBS sin relajar a `unsafe-inline`. Todo despliegue a producción o publicación externa permanece sujeto a autorización expresa de Kalista.

## Gates vigentes de F2

Consultar [verificación por candidata](verification.md), [recuperación](recovery.md)
y [deuda #55](https://github.com/tears-mysthrala/chat-overlay/issues/55).
SEC-13 (#51), SEC-17 (#49), eliminación integral (#48), cobertura ASVS (#42) y
validación web/OBS actual (#43) siguen abiertos. El diseño propuesto está en
[ADR 0005](adr/0005-f2-isolation-and-quarantine-proposal.md), sin aprobación todavía.
No usar los resultados históricos como autorización para publicar.
