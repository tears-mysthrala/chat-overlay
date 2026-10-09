# Aceptación de preview manual — 2026-10-09

Refs #64, #55. Base08d8f83def49b760a035bcacb3e0fef708272051.
No cambia runtime, dependencias, contratos ni producción.

## Evidencia de aceptación

La suite media_preview_test.exs cubre inventario activo del propietario,
rechazo A/B, objetos retirados/cuarentena/backend incorrecto, URLs externas,
anónimo/capability y origen inválido; sesión revocada, doble petición/cooldown,
caducidad y ausencia de replay/snapshot. HTTP/SSE real entrega solo al overlay
protegido; el lector y la reconexión omiten la alerta.

Nueva regresión: detener la autorización con una barrera de mensajes, cambiar
configuración o retirar el objeto y permitir continuar. La selección actual
rechaza ambos casos sin emitir preview. No usa sleeps para provocar la carrera.
Se ejecutó en chat-overlay:70-validation con test/ montado readonly, sin red,
2CPU/1GiB/128PIDs y +S2:2: seis pruebas PASS seed0.
Primer intento usó /app y no encontró mix.exs; corregido a /build.
Primer formato detectó una línea larga; corregida sin cambiar comportamiento.

Contrato tipado, TTL10s, volumen35%, cola única, deduplicación32IDs y parada al
desconectar constan en docs/event-contract.md y priv/static/app.js.
CSP conserva rutas del mismo origen y no permite unsafe-inline.
Imagen y audio en OBS real tienen evidencia anterior en el registro
2026-10-07-obs-preview.md y las pruebas posteriores al corte de PR68;
el operador confirmó audibilidad. No se repitió una emisión en Twitch.
La revisión oficial OpenAI e28c1e39 consta en aquel registro. No se presenta
como revisión de esta nueva prueba. Formato final PASS y Auto Review Codex exit0 sin hallazgos accionables sobre la nueva prueba. CI final de esta unidad pendiente.

## Límites y rollback

Preview manual no acredita follows/subs ni eventos automáticos.
#69 sigue independiente: inyección del borde incompatible con CSP.
Revert de esta unidad retira prueba y evidencia; no altera datos ni producción.
