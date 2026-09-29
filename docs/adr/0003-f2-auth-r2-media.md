# ADR 0003 — Arquitectura F2: Autenticación OAuth, Capability Tokens y Módulo Multimedia R2

Estado: Aprobada por Kalista el 29-09-2026 para issue #17.

## Motivo y contexto

Tras completar y validar la Fase F1 (overlay básico unificado para Twitch y YouTube con OBS Studio 32.2.2 en vivo), la Fase F2 amplía el servicio para permitir acceso autónomo de creadores con dos objetivos centrales de diseño:
1. **Fricción cero y cero consumo en el PC del streamer**: El creador no debe compilar, gestionar contenedores ni correr servicios pesados mientras emite; toda la agregación y entrega ocurre en `chat.mysthrala.com`, y en OBS solo introduce una URL de fuente de navegador.
2. **Cero custodia innecesaria y costes mínimos en el servidor**: No asumir el coste ni el riesgo legal/RGPD de alojar gigabytes de archivos multimedia de terceros en los servidores de la aplicación, manteniendo el nodo Elixir enfocado exclusivamente en streaming de eventos en memoria RAM.

## Decisiones arquitectónicas

### 1. Autenticación y control de acceso (SEC-12, SEC-14)
- **SSO con plataformas de streaming (Twitch / Google)**: Flujo oficial OAuth 2.0 con PKCE (`code_challenge` SHA-256) y parámetro `state` firmado criptográficamente para prevenir CSRF y suplantaciones. Evita la fricción de requerir cuentas de desarrollador (como GitHub) a streamers de entretenimiento.
- **Sesión disociada**: La sesión web del panel utiliza cookies firmadas y cifradas (`HttpOnly`, `SameSite=Lax`, `Secure`), separadas de las credenciales de plataforma.
- **Tokens de OBS (`Capability Tokens`)**:
  - Para evitar exponer sesiones de usuario en OBS, el overlay consume una URL con un token opaco aleatorio de 32 bytes (`https://chat.mysthrala.com/overlay/<handle>?token=<token>`).
  - La verificación utiliza comparación de tiempo constante (`:crypto.secure_compare/2`) para prevenir ataques de temporización.
  - El creador dispone de un botón visible de **«Regenerar enlace de OBS»** en su panel, que invalida inmediatamente el token anterior si se expone accidentalmente en pantalla durante una retransmisión. Al tratarse de un token de sólo lectura para un chat que ya es público, su revocación en caliente mitiga el incidente sin requerir notificación a la autoridad de protección de datos (RGPD Art. 33).

### 2. Custodia de credenciales (SEC-15)
- Los tokens de acceso de Twitch y YouTube necesarios para la lectura de eventos se cifran en reposo utilizando **cifrado simétrico autenticado AEAD (AES-256-GCM)** mediante la función nativa de Erlang/OTP `:crypto.crypto_one_time_aead/6`.
- Esto garantiza confidencialidad e integridad sin introducir dependencias externas adicionales en el árbol de Mix ni implementar algoritmos propios.
- Las claves maestras se inyectan exclusivamente por variables de entorno y los nonces se generan de forma aleatoria por registro.

### 3. Módulo Multimedia: Audios y Emojis de Alerta (SEC-05, SEC-17)
Se implementa una arquitectura híbrida de medios:
- **Modo Enlaces Externos (Universal)**: El creador puede configurar URLs directas existentes (ej. CDN de Discord, Dropbox o web propia). El servidor almacena 0 bytes y no asume custodia de archivos.
- **Modo Subida Directa Cloudflare R2 (Asignación manual / Early Adopters)**:
  - Se utiliza almacenamiento de objetos compatible con S3 en **Cloudflare R2 con jurisdicción en la Unión Europea (UE)** y **cero costes de transferencia saliente (*Zero Egress Fees*)**, protegiendo el proyecto de facturaciones imprevistas por reproducciones recurrentes en OBS.
  - El backend en Elixir genera **Presigned PUT URLs** compatibles con AWS SigV4 utilizando primitivas criptográficas nativas (`:crypto.mac(:hmac, :sha256, ...)`), sin dependencias pesadas de SDKs de terceros.
  - El archivo viaja **directamente desde el navegador del creador al bucket de R2**; los bytes del archivo jamás transitan por el nodo Elixir ni tocan el disco del servidor.
  - **Validación de tipos y tamaños**:
    - Audios: `.mp3`, `.ogg`, `.wav`, `.webm` (máximo 2 MB por archivo).
    - Emojis/alertas visuales: `.webp`, `.png`, `.gif` (máximo 512 KB por archivo).
    - **Prohibición estricta de `.svg`**: Se rechaza cualquier archivo SVG para eliminar vectores de ataque XSS mediante scripts embebidos en el motor Chromium CEF de OBS.
  - Cuota acotada por creador (por defecto 10 MB), suficiente para varios efectos de audio y decenas de emojis.

### 4. Gobernanza, Autoría y RGPD (COMP-07)
- **Autoría del creador**: Los términos de servicio estipulan que el usuario mantiene el 100% de los derechos de autor sobre sus audios e imágenes; la plataforma actúa como mero conducto técnico para la visualización en OBS.
- **Derecho al olvido (Art. 17 RGPD)**: El panel incluye la acción «Eliminar mi cuenta», que purga en una única operación el perfil del usuario, revoca sus tokens y elimina sus archivos asociados en el bucket de R2.

## Consecuencias y alternativas descartadas
- **Descartado UploadThing**: No dispone de SSO con Twitch ni API de aprovisionamiento de cuentas de usuario final para consumidores; obligaría a cada streamer a crear una cuenta de desarrollador en GitHub y generar API keys, introduciendo una fricción inasumible.
- **Descartado AWS S3 tradicional**: Su nivel gratuito caduca a los 12 meses y factura tarifas elevadas por tráfico de descarga saliente (*egress fees*), lo que supone un riesgo financiero ante descargas continuas de OBS.
- **Descartado Proton Drive para streaming**: Su arquitectura de cifrado de extremo a extremo (E2EE) impide la entrega directa mediante URLs de streaming crudas (`<audio src="...">`), añadiendo latencias incompatibles con alertas en directo.

## Fuentes
- [Cloudflare R2 S3 API](https://developers.cloudflare.com/r2/api/s3/api/)
- [AWS Signature Version 4](https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html)
- [Twitch OAuth 2.0 PKCE](https://dev.twitch.tv/docs/authentication/register-app/)
- [Erlang/OTP Crypto AEAD](https://www.erlang.org/doc/man/crypto.html#crypto_one_time_aead-6)
