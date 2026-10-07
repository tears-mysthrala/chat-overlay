# Unidad #62: almacenamiento local privado

Rama `feat/62-local-media`, worktree `chat-overlay-local-media`, base9250d51.
Autorización: almacenamiento inicial en disco de Benten, sin contratar S3/R2;
mantener cuarentena privada y decoder aislado aprobado en ADR0005.

Implementado, todavía sin commit ni despliegue: Disk Linux con rutas hash,
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

Pendientes que bloquean entrega: revisión oficial OpenAI del diff,
PostgreSQL, imagen/SBOM/escaneo, configuración del servicio privado/Firewall,
despliegue con rollback y permisos, subida real en panel y validación en OBS.
No declarar almacenamiento local desplegado ni SEC17/ARCH06 cerrados.

Continuidad lectores: Twitch real desplegado y confirmado a las15:06 mediante
un mensaje autorizado desde el navegador propietario, recibido una sola vez
en el lector. Ver registro de #47 en el worktree oauth-readers. YouTube no tiene
chat activo probado y OBS actual no se ha probado. Socket local4455 no respondió
en el sondeo de un segundo; no se modificó configuración de OBS.
