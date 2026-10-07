# Unidad #62: almacenamiento local privado

Actualización 16:20 CEST: revisión oficial Codex Security
`4a10c926-6133-4394-8c9a-5c5963fcd00b` completada sobre860deeb, sin vulnerabilidades
reportables del diff; revisión de arquitectura independiente con GPT-6.1-Sol.
La cobertura conserva preguntas operativas y no acredita cierre de F2.

Imagen runtime `sha256:a42d61be3a9fe8ed969787f48288cd6330967c5b734296a7cadf8b2dd2811b6d`:
build/formato/compilación PASS; CycloneDX1.7 válido295 componentes;
Grype0 hallazgos activos,4 cubiertos por VEX aprobado vigente. Imagen validation
`sha256:15d81f56af8f1396b3dd2c3d8ef752ef0faef7f66958c5f5cfb20bd9a7658484`:
PostgreSQL/RLS26 PASS en seeds0 y424242; boot/mutación/restart PASS. Proyecto
sintético `overlay62-f29ee4b7a5d6` retirado con su volumen, sin tocar otros servicios.

Desplegado en Benten9502: coordinador systemd `chat-overlay-media.service`,
Python3.13.5, código revisado en `/opt/chat-overlay/media-62`, datos privados en
`/var/lib/chat-overlay/media-local`, directorios700/SQLite600, root confiable sin
capabilities y NoNewPrivileges. Token dedicado600, distinto de plataformas/OBS,
compartido únicamente con backend autorizado. Bind172.30.96.1:4199, firewall
permite solo172.30.96.2; backend fijado a esa IP. Decoder aprobado89432cb…
verificado por imagen/fuentes/runtime/VEX antes de escuchar; sin modificaciones.
Aplicación65532:65532/rootfs readonly, sin socket Docker. HEAD privado404 y
readiness PASS. Perfil tearsmysthrala can_upload habilitado por escritor
serializado con aplicación detenida; cuentas Twitch/YouTube activas preservadas.

Backup privado previo: `/var/lib/chat-overlay/backups/media-62-860deeb`, compose,
runtime.env, nftables y pg_dump; no es copia externa. Imagen previa a9c03ede…
conservada. Reinicio invalidó sesión por diseño; OAuth Twitch existente completó
reautenticación sin nuevos scopes. Panel muestra multimedia local y permiso de
subida. La resincronización retiró fuente del evento YouTube eliminado, conservó
cuenta vinculada y fuente Twitch. Ambos eventos de prueba fueron eliminados con
confirmación explícita de borrado permanente; no se comenzó emisión de vídeo.

Flujo real del panel PASS: el usuario seleccionó manualmente PNG112 y WAV2s;
Guardar alertas devolvió éxito. PUT privado, decoder aislado y publicación local
completaron el flujo. PNG público 28741 bytes/SHA256
8410bff123f60c3ef16c4c6818d557f696682d802f210909016b1ff5dcfd591c;
WAV público SHA256 c98983a5c992f58ff3ded93c69154e01188c70b0407a58fe33c7bebf9214a358.
Ambos archivos descargados coinciden con fixtures normalizados. Cuota panel430.7KB,
pendientes215.1KB. Puerto privado4199 inaccesible por LAN; original cuarentena404.
El permiso file URLs estaba activo; falló el selector de la herramienta, resuelto
con selección manual, no mediante rebajar controles.

La prueba de sonido del panel no envía multimedia a OBS. Preview manual #64
propuesto y aprobado expresamente, en rama separada feat/64-obs-preview.
OBS tras refresh real muestra Twitch: conectando (SSE recuperado); la sonda Python
403 de Cloudflare no prueba revocación. Sin streaming/grabación activos.
Revocación actual, representación multimedia OBS, mantenimiento índice4096/journal128,
backup externo/restore, ARCH06 y CI/publicación permanecen separados.

Rama `feat/62-local-media`, worktree `chat-overlay-local-media`, base9250d51.
Autorización: almacenamiento inicial en disco de Benten, sin contratar S3/R2;
mantener cuarentena privada y decoder aislado aprobado en ADR0005.

Implementado en860deeb y desplegado según la actualización anterior: Disk Linux con rutas hash,
O_NOFOLLOW/O_EXCL, índice privado, cuotas globales y tombstones durables;
adaptador del coordinador existente y API autenticada privada; relay de bytes
desde la API del producto con sesión, prueba AEAD y reserva; ruta de salida
solo para PNG/WAV normalizado inventariado y con hash verificado. Ledger,
activación y limpieza conservan backend y rechazan mezcla sin migración.
Frontend transmite la prueba en headers, sin URL sensible.

Validación ejecutada:

- Imagen de validación Elixir787d0289, Docker sin red: compilación sin warnings
  y suite general286 PASS seed0 antes de añadir las pruebas nuevas.
- Cuatro pruebas nuevas de flujo local PASS: autorización/bytes exactos,
  proof ligada a propietario, originales no públicos, hash y backend mixto.
- Python3.13 Alpine, Docker sin red: ocho pruebas reales de filesystem Linux
  y API privada PASS. Inmutabilidad, restart, borrado anterior a subida,
  cuotas compartidas, traversal, symlink, huérfanos, bytes alterados,
  autenticación, sealed y originales no descargables.
- Se corrigió una advertencia de tipo por is_map redundante; no se ignoró.

Suite completa final con últimas modificaciones:290 PASS seed0; compilación
sin warnings PASS. JavaScript syntax check y Python AST PASS; diff check PASS.

Decoder real89432cb3: diez copias PNG112 de emotes y WAV sintético2s PASS,
bytes/hashes verificados. Originales preservados por comparación SHA256.
Prueba Linux real Disk→LocalCoordinator→decoder→publicación→reinicio→borrado
y rechazo de PUT tardío/cancelación PASS para PNG y WAV (test_local_media_e2e).
Fedora Docker clásico importa el mismo bundle con ID8274808e; se verificaron
iguales capas RootFS, Config, arquitectura y OS frente a Docker Desktop89432cb3.
No se sustituyó la identidad VEX de despliegue; esa identidad sigue89432cb3.

Pendientes que bloquean aceptación funcional: subida real en panel y multimedia
en OBS. SEC17/ARCH06 no se declaran cerrados por este despliegue.

Continuidad lectores: Twitch real y chats pre-live de ambos eventos YouTube
confirmados en lector y OBS antes de cancelar los eventos. La prueba YouTube
usa URL explícita de evento programado; no acredita ciclo de vídeo emitido ni
autodetección del canal durante un directo. Ver registro #47 del worktree
oauth-readers. Multimedia nueva y revocación actual de OBS siguen pendientes.
