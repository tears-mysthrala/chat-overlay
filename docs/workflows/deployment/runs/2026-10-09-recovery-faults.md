# Fallos de escritura y muerte durante staging — 2026-10-09

Refs #40, #55. Base2c95cf03401c4f81587e5b2f89c0b6970a348af7 (PR79).
No cambios de runtime ni producción: harness de desarrollo y CI.

EIO y SIGKILL se inyectan en el proceso BEAM que escribe el payload real,
mediante LD_PRELOAD de una biblioteca C que solo actúa sobre descriptores cuyo
path comienza /faultout/.recovery- y contiene /payload. No altera otros archivos.
Cada escenario tiene un contenedor nuevo, rednone,2CPU/1GiB/128PIDs,+S2:2,
fixtures sintéticos y una copia anterior completa fuera de ese destino.

EIO PASS: Recovery.backup devuelve erroreio, no publica destino y limpia staging.
SIGKILL PASS: proceso termina137 durante escritura, no publica destino, deja un
único staging privado700. Muerte no ejecuta finally: se detecta y retira únicamente
ese huérfano de la fixture. No se afirma limpieza automática tras caída.
Ambos conservan hashes exactos del original y backup anterior; restore del backup
anterior conserva documento exacto y reintento posterior sin inyección publica.
La etapa se añadió a source-and-tests; compilador/harness solo en
Dockerfile.recovery-faults, nunca en Dockerfile/runtime.

Imagen de ensayo74cf165adc41c458707bf2feef5bb791f8447635c89103d4b0e0b7b7f9e2d9fe.
C compila con Wall/Wextra/Werror, formato Elixir PASS. Primer intento usó
sha256sum --check no soportado por BusyBox; corregido a -c y ambos casos reejecutados.
Auto Review inicial supuso pérdida de LD_PRELOAD: rechazado tras ejecutar EIO y
SIGKILL en BEAM y comprobar sus resultados; revisión final Codex exit0 sin hallazgos accionables, limitada al bundle.

Complementa seis tests recovery y siete auxiliares de PR79, más ENOSPC real.
Formato/key_id/custodia y efectos sesiones/capabilities/workers/rollback están en
recovery.md. #40 alcanza su matriz de ensayos/procedimiento; CI final pendiente.
Periodicidad/custodia redundante/descarga remota independiente siguen en #38;
no acredita corte eléctrico, hardware físico, producción ni disponibilidad global.
Rollback: revertir harness y etapa CI; no cambia datos ni claves.
