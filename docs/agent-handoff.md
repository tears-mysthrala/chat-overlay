# Handoff F1 — issue #15 (Cierre y consolidación de entrega Fase F1)

- Issue: https://github.com/tears-mysthrala/chat-overlay/issues/15
- Rama: `docs/15-f1-closure`
- Worktree: `/home/tears/github/tears-mysthrala/chat-overlay-worktrees/15-f1-closure`
- PR previa: https://github.com/tears-mysthrala/chat-overlay/pull/14 (MERGED en main `1f49e29`).
- Autorizado: Cierre formal y consolidación de la Fase F1 (overlay para Twitch y YouTube en OBS Studio sin Chatterino, y diferimiento formal de Kick por inestabilidad de API upstream). Aprobado y solicitado por el operador Kalista en issue #15.

## Resumen del estado de entrega de Fase F1:

1. **Plataformas operativas integradas en overlay unificado**:
   - **Twitch**: Integración oficial vía Helix API + EventSub WebSocket con reconexión limpia y drenaje de buffers. Descubrimiento de enlaces sociales mediante GraphQL web parametrizada (`query($login: String)`) con fallback a biografía de Helix y mecanismo de desactivación (`CHAT_DISABLE_TWITCH_GQL`).
   - **YouTube**: Soporte dual de credenciales (OAuth 2.0 Bearer y Google API Key restringida vía `X-Goog-Api-Key`), autodetección de emisiones activas de chat en vivo (`activeLiveChatId`), sincronización atómica en caliente sin reinicio de Store (`Store.update_sources/2`) y desvinculación limpia al terminar directos.
   - **Kick**: Formalmente **DIFERIDO / SUSPENDIDO** por directriz del operador Kalista (issue #15) debido a la reiterada inestabilidad técnica de su API de desarrolladores (4-5 breaking changes en el último año) y a la fricción operativa de su portal, evitando deuda técnica recurrente en componentes no estabilizados por el proveedor.
   - **Multistream unificado**: Agregación de chats de Twitch (morado) y YouTube (rojo) en la misma feed con badges diferenciados, soporte UTF-8 completo, filtrado de duplicados y mitigación XSS estricta (DOM text nodes).

2. **Validación en OBS Studio 32.2.2 en vivo**:
   - Verificado mediante prueba reproducible y automatizada contra OBS Studio 32.2.2 real (`obs-browser` CEF 152.0.7977.83 en Linux/Hyprland) sobre WebSocket v5 (`scripts/test_obs_validation.py`).
   - Canal alfa RGBA transparente verificado en renderizado (RGBA=0 fuera del área de mensajes).
   - Ocultación y reactivación de la fuente de navegador probada con reconexión instantánea de SSE y reemisión de snapshot sin mensajes duplicados.
   - Ciclo de vida inocuo con restauración automática de configuraciones previas (`overlay: False` y visibilidad de escenas).

3. **Fiabilidad, límites y carga sintética (REL-08)**:
   - Ejecución de `scripts/load.exs 60` (29-09-2026): 4.500 eventos emitidos sobre 10 perfiles y 100 visores SSE concurrentes.
   - 45.000 entregas recibidas (100% de éxito, 0 errores).
   - Latencia p95 despacho local -> SSE: **49 ms** (objetivo contractual: <100 ms).
   - Consumo de memoria BEAM: 468 MB -> 365 MB tras recolección de basura activa sin fugas.

4. **Seguridad y cadena de suministro (SUP / SEC)**:
   - Contenedor Alpine 3.24.2 endurecido, ejecución sin root (UID 65532), raíz de solo lectura y capacidades eliminadas.
   - Dependencias Hex auditadas al 100% limpias (0 advertencias) tras actualización a `mint 1.11.0` y `hpax 1.1.0`.
   - SBOM CycloneDX 1.7 automatizado (292 componentes).
   - Auditoría de vulnerabilidades con Grype: **0 vulnerabilidades activas** (4 excepciones de bajo nivel en paquetes base de Alpine justificadas y firmadas por Kalista en `vex.openvex.json`).
   - Detección de secretos con Gitleaks: 0 hallazgos.
   - Suite ExUnit: **78/78 pruebas PASS** con 0 advertencias de compilación (`--warnings-as-errors`).

5. **Próximo hito (Fase F2)**:
   - Apertura de la Fase F2 (Panel de Creador con autenticación de usuarios, cuentas privadas y persistencia durable en PostgreSQL con RLS) sujeta a autorización y definición de alcance por parte de Kalista.

Rollback: revertir al commit `1f49e29` en `main`. Al tratarse únicamente de consolidación documental, contratos y verificación, no introduce incompatibilidades de código ni de datos.

