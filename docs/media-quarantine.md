# Cuarentena local — unidad B ADR0005, Refs #49

Autorización A/B del 05-10-2026: implementación y pruebas locales. Sin cuentas,
infraestructura, permisos R2, DNS, publicación, merge ni despliegue reales.

## Cadena implementada

El backend reserva entrada privada y firma PUT para el bucket de cuarentena.
No entrega URL pública del original. Content-Length, Content-Type e If-None-Match
están firmados; el navegador envía `If-None-Match: *`. El nombre de entrada es
aleatorio y el firmante privado no necesita permisos sobre el bucket público.
R2 declara soporte para [PUT condicional](https://developers.cloudflare.com/r2/api/s3/api/).
El uso concreto con la cuenta del operador sigue sin probarse.

`POST /api/media/validate` exige origen, JSON, sesión/perfil y token de la entrada.
El escritor comprueba nuevamente permiso y reserva, genera un job y reserva el
máximo de salida además del tamaño de entrada. I/O remoto queda fuera del escritor.
La finalización comprueba nuevamente autorización y permiso dentro de la mutación.
Un reporte de otro perfil, categoría, job, entrada o hash/formato inválido no activa
el archivo. Reintentar una respuesta lista no crea otra reserva ni otro decoder.

El coordinador recibe solo metadatos por HTTP autenticado en loopback. Descarga
bytes privados con destino fijo, ejecuta el decoder y verifica independientemente
estructura, tamaño y hashes. Publica solo la salida normalizada con PUT condicional,
nombre derivado de job/hash y lectura posterior que confirma los bytes exactos.
El frontend asocia el artefacto público listo, no la entrada. La salida es PNG
RGBA estático de hasta 1024x1024/512 KiB o WAV PCM16 mono 48 kHz de hasta 10 s/2 MiB.
WAV se canoniza a fmt/data, sin metadatos adicionales. No se recorta contenido
excesivo: se rechaza. Los originales nunca se copian al bucket público.

## Aislamiento y límites

Cada job usa imagen inmutable por ID, usuario 65532, rootfs readonly, sin red,
capabilities, privilegios nuevos, credenciales, datos de otros perfiles ni socket
Docker. Solo monta el archivo de entrada readonly. Salida/tmp son tmpfs privados
noexec/nosuid; 1 CPU, 256 MiB, sin swap adicional y 32 PID. Logs se limitan a 64 KiB.
El decoder comparte un deadline de nueve segundos; el launcher tiene diez y
retira el contenedor incluso ante timeout. Un fallo de retirada no devuelve éxito.

El launcher es servicio confiable del operador: su acceso al daemon Docker **no**
pertenece al backend HTTP ni al contenedor que decodifica. Root/daemon/host
comprometidos quedan fuera de esta frontera. Windows ACL de staging no se acredita
como aislamiento entre administradores. No se ha desplegado este servicio.

## Configuración preparada

Backend: metadatos `R2_ENDPOINT`, `R2_BUCKET`, `R2_PUBLIC_CDN`,
`R2_QUARANTINE_BUCKET`; firmante privado `R2_QUARANTINE_ACCESS_KEY_ID` y
`R2_QUARANTINE_SECRET_ACCESS_KEY`; `MEDIA_COORDINATOR_TOKEN` aleatorio base64url
de 43–128 caracteres. Port por configuración de aplicación, por defecto 4199.
El CORS privado debe aceptar PUT y los headers Content-Type/If-None-Match del
origen permitido; esto es preparación, no un cambio aplicado a buckets reales.

Coordinador: mismo endpoint y nombres de buckets distintos, credenciales privadas
`COORD_QUARANTINE_ACCESS_KEY`/`COORD_QUARANTINE_SECRET`, y públicas
`COORD_PUBLIC_ACCESS_KEY`/`COORD_PUBLIC_SECRET`, limitadas a los buckets respectivos;
`MEDIA_VALIDATOR_IMAGE=sha256:...`, `MEDIA_COORDINATOR_JOURNAL` privado y token.
Ejecutar `python scripts/media_coordinator.py` en el host del launcher autorizado.
El journal SQLite tiene hasta 128 jobs y cancelaciones; backlog HTTP ocho, un
decoder simultáneo. Al llenarse rechaza nuevos jobs; no borra deuda automáticamente.
Es un límite acumulado, no únicamente concurrente: tras 128 jobs históricos
requiere mantenimiento sellado. No se acredita operación continua sin intervención.

## Reconciliación y retirada

DELETE de un original no demuestra que un PUT firmado tardío haya terminado.
En modo normal el servicio devuelve `reconcile` para cuarentena, conserva los
bytes privados y su cargo. El borrado público se confirma por lectura ausente
y cancela el job de forma durable antes de eliminar, evitando repromoción.
Las promociones públicas inciertas también conservan reserva y objeto hasta
reconciliación sellada. La incertidumbre se registra antes de PUT y sobrevive a
timeouts, reinicios y reintentos confirmados. DELETE/GET404 no cancela un PUT
anterior. Un placeholder público `/pending` tampoco se libera en modo normal.

Para liberar cuarentena, el operador debe detener la aplicación y la emisión de
subidas, revocar el firmante de PUT y verificar que todas las escrituras privadas
y públicas pendientes han drenado. Solo entonces iniciar mantenimiento con
`MEDIA_UPLOADS_SEALED=1` en backend/coordinador y credenciales de mantenimiento.
Esta variable **declara una precondición del operador**, no verifica R2 por sí sola.
El coordinador rechaza normalización y el backend deja de emitir subidas; se
confirma DELETE/GET ausente antes de liberar la reserva. No activar el flag sobre
infraestructura real sin esa preparación y autorización independiente.

Tras reconciliar el inventario durable y retirar todos los objetos registrados,
con aplicación/coordinador normal detenidos, ejecutar el coordinador con
`--compact-sealed`. Verifica ausencia de entradas y salidas antes de limpiar el
journal; no hay ruta HTTP de compactación. Las lecturas ambiguas conservan registros.
Rotar credenciales/token antes de reabrir. Se prueban estas precondiciones con
storage sintético; no se acredita drenaje ni borrado en una cuenta R2 real.

Rollback: detener las subidas/coordinador, conservar inventario y journal, volver
a la candidata anterior solo con subidas deshabilitadas. No activar originales
ni liberar cuota al retirar el decoder. La conciliación de datos previos sigue #48.

## Dependencias y publicación

Decoder fijado: Alpine 3.24.2 por digest, Python 3.14.8-r0 con cuatro parches
oficiales fijados por SHA256, y FFmpeg upstream commit
`e5a08f7c0e45e6d278a394ef19c97f0b8ad3ed45`, fuente verificada por checksum.
La compilación mínima desactiva autodetección, red, hardware y codecs ajenos al
contrato. Se conservan los formatos de entrada PNG/GIF/WebP y MP3/OGG/WAV/WebM.
GIF usa parser obligatorio; APNG y WebP animado se rechazan por estructura antes
de decodificar. WebM puede omitir duración declarada: siempre se comprueba el PCM
completo, nunca se trunca a diez segundos para conseguir aceptación.

La primera imagen con FFmpeg Alpine completo era GPL y tenía 210 matches. Se
retiró ese paquete. La compilación mínima declara LGPL 2.1 o posterior y conserva
su texto; Python conserva PSF y los parches/avisos. FFmpeg explica cómo su configuración puede activar GPL en su
[documentación de licencia](https://ffmpeg.org/legal.html). Antes de distribuir
binarios hay que preparar fuentes correspondientes, avisos/licencias y revisar
las transitivas nativas del SBOM; no basta con atribuir LGPL a todo el conjunto.
Este trabajo local no autoriza ni acredita distribución legal/publicación.

Los parches CPython se aplican sin fuzz; siete regresiones upstream y una
comprobación obligatoria equivalente de limpieza FD-relative pasan como UID65532.
La prueba upstream `test_cleanup_safe` se salta en musl por metadata de tier; se
ejecuta aquí su misma aserción sin ese filtro. El parche tempfile/shutil de la PR
158430 todavía no está incluido en una release oficial; es un backport local.
Procedencia y checksums: `vendor/media/python/SHA256SUMS`; inventario del binario
FFmpeg y archivos Python en `/usr/share/media-components.json` y SBOM.

El scanner sigue identificando Python por la versión APK original y Busybox por
la imagen base. Se conservan esas coincidencias sin VEX de decoder aprobado;
no se transfiere silenciosamente la excepción del runtime BEAM a esta imagen.
Antes de publicar hay que revisar el backport local, la cobertura del commit
FFmpeg sin versión release y la declaración de aplicabilidad del decoder.

CI prepara pruebas reales del decoder/coordinador y SBOM CycloneDX 1.7 validado
con gate de vulnerabilidades de todas las severidades sobre la imagen exacta.
Tests del control BEAM usan replies sintéticos; tests HTTP del coordinador Python
usan decoder real y almacenamiento sintético. No son una prueba en R2, OBS ni un
ensayo de explotación del kernel. ARCH-06 y los restantes gates de F2 siguen abiertos.
