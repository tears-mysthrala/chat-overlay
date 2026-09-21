# Verificación F1 — issue #3

Estado de implementación local: en revisión. **F1 no ha superado su puerta de publicación.** Los pendientes externos están en [#4](https://github.com/tears-mysthrala/chat-overlay/issues/4). No presentar pruebas sintéticas como vivo ni Chromium como OBS.

| Área / contrato | Evidencia reproducible | Resultado local |
| --- | --- | --- |
| DEV-01/04/16 | `scripts/check_traceability.py`, issue #3, rama/worktree propio | PASS; issue real y remoto verificados |
| ARCH-01/SEC-03 | `mix check`: formato, compilación y ExUnit | 39 pruebas; sin advertencias de compilación |
| REL-01/02/03 | event/adapters/store tests | Esquema, Unicode, dedup, borrados, caducidad, filtrado y replay |
| REL-04/06 | store/socket/http tests | Límites de historial/replay/tombstones/JSON/frames/cuerpo y rutas |
| Recuperación | HTTP/source tests | Caída aislada, tareas sin huérfanos, demanda/gracia y espera de cuota conservada |
| Protocolos | connectors/socket tests | YouTube continuación/espera/página Unicode, identidad Twitch, handshake TCP real, fragmentos/ping, errores Kick |
| SEC-05/07 | Chromium 153 local | Texto HTML literal sin nodos ejecutables, assets locales, móvil sin overflow, fondo transparente, recarga y reconexión tras reinicio |
| SEC-06 | event tests + Net | Destinos cerrados, IP privada/IPv6 y URL de reconexión maliciosa rechazados; TLS en producción configurado |
| SEC-08 | `scripts/smoke_image.py` | Arranque real no root, raíz read-only, límites efectivos, CSP, readiness y SSE |
| SEC-10 | `scripts/scan_secrets.py` | 0 hallazgos en instantánea de fuente; no certifica historia completa |
| SUP-02/06 | Hex 2.5.1 y `scripts/inventory.exs` | 0 avisos/retirados Hex; 10 paquetes con licencias/textos/hashes |
| SUP-04 | `scripts/audit_image.py` | CycloneDX 1.7 válido, aplicación + runtime + imagen; 292 componentes en artefacto inspeccionado |
| SUP-07 | Grype, sin supresión | FAIL: 4 coincidencias (1 High, 3 Medium; 2 CVE), ver dependencies.md |
| REL-08 | `scripts/load.exs 60`, Docker 2 CPU/1 GiB | 4.500 eventos emitidos, 45.000/45.000 entregas, 0 errores, p95 51 ms; RAM BEAM 343.278.104 → 373.720.184 bytes |
| DEV-13/REL-08 | Vivo, OBS y 4 h/24 h | Pendientes; bloquean candidata/publicación según contrato |
| COMP-01/10/SUP-05 | Matriz normativa, condiciones de plataforma, firma/procedencia | Pendientes de revisión humana antes de publicar |

## Método y límites

ExUnit usa fixtures sintéticas, transporte HTTP local y un servidor WebSocket de prueba; no contacta APIs reales. Windows: Elixir 1.20.4/OTP 29.0.6. Docker Linux amd64: Elixir 1.20.4/OTP 29.1 sobre Alpine 3.24.2. El build de validación corre `mix check` y el build de runtime genera una release independiente sin Mix.

Carga: 10 perfiles, 30 fuentes demo, 100 SSE, mensajes de 512 bytes, 200 eventos/s durante 10 segundos y 50/s después. Las demos añaden una pequeña carga declarada. Reloj monotónico desde ingesta normalizada hasta recepción HTTP local; excluye upstream, Internet, navegador, OBS y cloudflared. 60 segundos no demuestra estabilidad durante horas. Los clientes y Mix comparten el contenedor de validación: la memoria indicada no es el mínimo de la release. Los resultados no son una promesa de capacidad pública.

Chromium: comprobado lector a 390 px, overlay transparente y HTML literal, recarga con máximo 100 mensajes, caída/reinicio real del servidor y reconexión con snapshot vacío por nueva época. Activar offline en el navegador no cortó la conexión localhost: esa acción **no** se contó como prueba de corte; se sustituyó por detener/reiniciar el contenedor local. Los errores de red durante ese corte son esperados.

Revisión estructurada con la skill autoreview (Codex, modo local, herramientas de solo lectura). Se verificaron y corrigieron los hallazgos sobre retención del replay, expulsión en vistas filtradas, borrados retrasados, cooldown tras cerrar lectores, handshake acotado, páginas YouTube y Retry-After en 5xx. Resultado final del helper: 0 hallazgos accionables, salida 0. No acredita publicación. CI: ver [registro](workflows/f1-delivery/runs/2026-09-20.md), que se actualiza con el cierre.

El repositorio no tenía protección efectiva de main al inspeccionarlo. No se cambiaron permisos: se mantiene como control operativo no hacer merge sin revisión humana y checks; el gate de imagen bloquea por los cuatro hallazgos conocidos. No se ha concedido una aprobación humana desde el agente.
