# Operación local y preparación de publicación

## Arranque, parada y actualización

Usar Compose para la demo local o construir `docker build -t chat-overlay:<revision> .`. No publicar el puerto en interfaces externas antes de superar los gates. La configuración se monta como solo lectura; no hay volumen de historial persistente de chats. `/health/live` confirma listener y `/health/ready` comprueba stores: no certifica conectividad upstream.

La imagen corre como UID/GID 65532. Compose elimina capacidades, impide nuevos privilegios, limita CPU a 2, memoria a 1 GiB y PID a 128, monta raíz de solo lectura y `/tmp` acotado. Desactiva distribución Erlang y vuelcos de crash a disco. La VM tiene dos schedulers y límites explícitos de procesos/puertos. No montar socket Docker, directorios del host o credenciales de otras aplicaciones.

Para actualizar: conservar configuración y referencias secretas fuera de Git, construir y probar un nuevo digest, comparar SBOM/avisos, detener la instancia anterior y arrancar la nueva con los mismos límites. Rollback: restaurar el digest anterior aprobado y su configuración. Rotar tokens cambiando el entorno o regenerando en caliente desde el panel; no imprimirlos ni pasarlos como argumentos de CLI.

## Acceso, Capability Tokens y observabilidad

El operador debe mantener TLS, proxy sin buffering SSE, segmentación y límites de conexión/rate a la entrada. Las IP reenviadas no son identidad. No hay log de contenido de chat ni tokens completos (los logs redactan a `token[:12]...`); los estados públicos omiten detalles de credenciales y errores upstream. Los mensajes de chat se retienen hasta 30 minutos/100 por perfil en RAM.

- **Capability Tokens para OBS**: Las URLs de overlay `/overlay/:handle?token=<token>` y de eventos `/events/:handle?token=<token>&view=overlay` requieren un token de capacidad opaco de 32 bytes URL-safe.
- **Revocación en caliente**: Desde el Panel de Creador (`/`) o mediante `POST /api/profiles/:handle/token/regenerate`, el token se regenera de forma atómica. El token previo queda revocado de inmediato en memoria y disco; cualquier fuente de OBS conectada con el token revocado recibe 401 Unauthorized sin interrumpir la ingestión de chat ni reiniciar el nodo.
- **Panel de Creador**: Accesible en `/`. Proporciona gestión de tokens con aviso previo de revocación, botón de copia rápida, configuración de alertas multimedia y reproductor de prueba de sonido integrado.

## Módulo Multimedia (Cloudflare R2 y URLs Externas)

- **Variables de entorno para R2 (opcionales)**:
  - `CHAT_R2_ACCOUNT_ID`: Identificador de cuenta de Cloudflare.
  - `CHAT_R2_BUCKET`: Nombre del bucket de R2.
  - `CHAT_R2_ACCESS_KEY_ID`: Credencial de acceso SigV4.
  - `CHAT_R2_SECRET_ACCESS_KEY`: Clave secreta SigV4.
  - `CHAT_R2_PUBLIC_BASE_URL`: Dominio público del bucket (p. ej. `https://media.mysthrala.com`).
- **Arquitectura Zero Server Footprint**: El servidor Elixir genera URLs prefirmadas PUT compatibles con AWS SigV4 de forma nativa en OTP (`POST /api/media/presign`). El cliente sube el archivo multimedia directamente a Cloudflare R2 sin consumir ancho de banda de red ni memoria en el backend.
- **Límites y restricciones de seguridad**:
  - Audios: `.mp3`, `.ogg`, `.wav`, `.webm` (máximo 2 MB por archivo).
  - Imágenes/emojis: `.webp`, `.png`, `.gif` (máximo 512 KB por archivo).
  - **Prohibición estricta de `.svg`**: Rechazado deterministamente para neutralizar ataques XSS contra el motor Chromium CEF de OBS Studio.
  - Cuota de almacenamiento: Enforceada por perfil (por defecto 10 MB).
  - URLs externas: Se validan contra SSRF (`ChatOverlay.Net.public_ip?/1`), resolviendo DNS y rechazando redes privadas, loopback y metadatos locales.

## Vulnerabilidades y gates

[SECURITY.md](../SECURITY.md) identifica el canal privado real y a Kalista como responsable. Conservar versión/digest, alcance y evidencia sin secretos; reproducir en aislamiento, corregir y repetir pruebas. El responsable decide distribución, comunicaciones y cualquier obligación de notificación; verificar normativa vigente al activar un incidente. No hacer notificaciones automáticas a terceros.

Cierre de Fase F2: gates de seguridad de imagen y SBOM validados en verde (Grype 0 vulnerabilidades, OpenVEX aprobado por Kalista, Hex audit limpio), ExUnit 110/110 pruebas PASS, carga sintética REL-08 (p95 49 ms), validación en vivo de Twitch y YouTube, validación en vivo automatizada en OBS Studio 32.2.2 en los 5 estados de capability tokens y canal alfa transparente, y CSP estricta autorizando hash de estilos de OBS sin relajar a `unsafe-inline`. Todo despliegue a producción o publicación externa permanece sujeto a autorización expresa de Kalista.
