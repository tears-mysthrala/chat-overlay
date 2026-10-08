# Corte del custodio y revisión de interfaz — 2026-10-08

Refs #39, #43. Autorización del operador en este hilo: continuar el despliegue separado y aplicar los nuevos criterios de diseño a web/chat. No se amplía a bots, runners o Kick.

## Producción comprobada

PR #67 integrada por autorización explícita, squash `cf2d3d32c4e091247830a536ba8512ba1d6e7dd5`. CodeRabbit APPROVED y diez checks PASS sobre `2ea6f1ed790c202b549fb11e8fef83571d9df783`.

VM Benten9502 ejecuta frontend y custodio separados, ambos con imagen revisada `sha256:90e3de9b3f2a180e4e049c99aedb3ba883adf38025634a5f4d81664941cc9c61`. PostgreSQL y coordinador multimedia conservados. Conteos posteriores: 1 perfil, 2 cuentas, 2 objetos.

- Frontend: sin claves de cifrado, contraseñas DB, secretos OAuth ni token del coordinador en su entorno; solo certificados cliente/CA montados; red boundary única; raíz de solo lectura. Sin procesos Config/Profiles/Tokens/Session.
- Custodio: ningún puerto publicado; raíz de solo lectura; mTLS con CA privada específica, servidor SAN custodian, certificados de 90 días.
- Conexiones TCP desde frontend: custodio4200 permitido; PostgreSQL5432, coordinador4199 e Internet443 rechazados. Reglas verificadas en `inet chat_overlay_guard`, sin flush global.
- HTTPS público y loopback readiness200; perfiles/reader sin sesión401 desde navegador nativo y loopback. El cliente Python del guest recibe403 desde el borde público; navegador y curl Windows reciben200. No se modificó Cloudflare para eludir esa diferencia.
- Backup previo cifrado CMS SHA256 `a0cfc5bc73996dbd0fd1200c23a6b1300a0d251318b17db946e76a55bee503d7`, copiado y hash verificado fuera del guest en output/cutover/precutover-backup.cms. No se publican contenido ni claves.
- Rollback: configuración anterior guardada en /var/backups/chat-overlay/cutover-20261008 y -retry. Imagen43ed8a7a conservada. El primer intento falló por CRLF en un script transferido; rollback automático comprobado antes de reintentar con bytes LF. No se restauraron datos históricos.

Una sesión creada con release eval no sirve al nodo activo por su época de sesión independiente. RPC no está habilitado (`RELEASE_DISTRIBUTION=none`); se mantuvo esa frontera. No se acredita login/logout/SSE autenticado real posterior al corte a partir de ese intento. La sesión temporal y su archivo se eliminaron; no se cambiaron perfiles. Nuevo consentimiento OAuth y smoke OBS real posteriores al corte siguen NOT TESTED. Las pruebas anteriores a este corte son historial, no evidencia de esta topología.

## Candidata de diseño local

Rama chore/39-custodian-cutover-ui, base cf2d3d3. Aplicados ui-quality, responsive-quality, accessibility-quality y unslop. Objetivo de implementación WCAG2.2 AA, sin declaración de conformidad global.

- Entrada anónima como acceso al panel, sin mostrar controles privados ni confundir401 con fallo de conexión. Formulario para perfil/cuenta ya vinculada usa autorización existente, sin crear bypass ni nueva dependencia.
- Jerarquía más compacta, navegación por tareas y texto de OBS/cuentas sin detalles internos innecesarios. Kick retirado del anuncio de disponibilidad.
- Tarjetas, controles y nombres largos refluye; ayuda OBS permanece en móvil; foco y saltos al contenido; targets pequeños ampliados; contraste del badge YouTube corregido; movimiento reducido; lienzo OBS conserva transparencia y altura.
- Regresiones anónima y recuperación OBS añadidas a la suite browser existente. Sin capability local, el acceso rápido OBS abre su gestión con explicación y foco; no copia un enlace incompleto.

327 ExUnit PASS seed0/max_cases1 y 327 PASS seed424242/max_cases16. Build validation: formato y compilación del producto con warnings-as-errors PASS; aviso heredado Postgrex xref deprecado registrado, no suprimido. Sintaxis JS, trazabilidad #39, scanner de secretos (cero leaks), estática específica (cero findings, reglas limitadas) y diff check PASS. Hook pre-push físico no instalado en este clon: sus comprobaciones se ejecutan por separado con Python/Docker; no se usa --no-verify ni se declara ejecución del hook.

Navegador nativo T3 Electron44.4.2/Chromium152: login sintético, aislamiento de perfiles403, HttpOnly, controles de permisos, error multimedia recuperable, regeneración/revocación y SSE PASS a1280 y390. Panel y chat sin overflow a320/390/768/1280; ayuda móvil visible. Estado anónimo y logout con limpieza de capability PASS. Perfil de acceso inexistente muestra error y rehabilita ambos botones. Evidencia sintética; sin conexión a plataformas reales.

Candidata previa a revisión `sha256:6eb18200135e1eaf489e76831e82460175ce539ee1e707491a2437ea61143ab7`: release smoke y separación real de dos releases PASS; CycloneDX295, cero findings activos, cuatro matches cubiertos por VEX aprobadas. Digest reconstruido tras los ajustes finales. HTTP/F2/sesiones/API42 PASS sobre assets finales. Login/aislamiento/regeneración/revocación/SSE y recuperación del enlace OBS PASS también a320 sobre assets finales. Teclado: salto activado con Enter lleva el foco al contenido; Tab alcanza el perfil y el botón Twitch con foco visible de3px.

Auto Review: dos intentos rechazados por permiso de exportación; el operador autorizó expresamente continuar esas acciones el08-10-2026. Ejecutado con Codex read-only, sin búsqueda web y bundle limitado al diff: exit0, cero hallazgos accionables. El shell de inspección del revisor no pudo inicializarse: juicio basado en el bundle, sin inspección adicional ni pruebas por el revisor. Las pruebas locales son evidencia independiente. Comando: python C:/Users/unaiu/.codex/skills/autoreview/scripts/autoreview --mode local --codex-bin C:/Users/unaiu/AppData/Roaming/npm/codex.cmd --no-web-search (prompt acota checkout y excluye output/secretos).

## Siguiente acción

Validación local final y Auto Review terminados. Publicar PR no draft, verificar CI y revisión del head exacto antes del merge y despliegue autorizado del diseño. OAuth/OBS reales posteriores al corte permanecen pendientes; no habilitar RPC para fabricar evidencia. #39/#43 permanecen abiertos.

## Corrección de revisión PR #68

CodeRabbit aprobó `8779a39` el08-10-2026 a06:45:58UTC; diez checks PASS y cinco hilos resueltos. Persistía un aviso de docstrings16,67% sobre seis funciones de tres archivos. Se documentan las funciones del dashboard y los drivers de navegador, sin cambiar comportamiento. Sintaxis Node de los tres archivos y `git diff --check` PASS. El nuevo delta documental requiere CI y revisión; la aprobación y la imagen anteriores no acreditan ese head nuevo.

CodexP2 confirmado: controles ocultos en HTML inicialmente; JSON se valida antes de mostrar el panel. Fallos de red/503/JSON inválido muestran acceso y recuperación, con reintento. Browser CI cubre los tres errores y regreso al estado anónimo.

CodeRabbit: handoff identifica PR/rama/issues/comandos; campo OBS vacío cuando falta capability; patrón de entrada admite mayúsculas y conserva normalización; test de recuperación usa atributos estables. No se cambió el contrato servidor de acceso a perfiles sin capability.

Navegador nativo indisponible tras desconectar la app T3. Fallback local Playwright1.63 con Edge headless y red sintética: errores/recuperación más suite desktop/móvil PASS; sin requests externos ni errores de página/CSP. Descarga del Chromium empaquetado falló por timeout; no se extrapola ese intento a un PASS. Evidencia output/browser/result.json (privada, sin tokens). Auto Review del delta de carga: exit0, sin hallazgos. Últimos ajustes CodeRabbit: suite desktop/móvil PASS en Edge156.0.4314.8, cero errores JS/CSP y cero requests externos. Auto Review del diff final exit0, cero hallazgos accionables; scripts de sintaxis/secretos/estática/diff PASS. Imagen reconstruida `sha256:e16ebb14cfcc8671dfda780d9e9d89afef310e1f5af75ab12cfc4875992588e8`, smoke PASS; auditoría final PASS (SBOM295, cero activos, cuatro VEX), identidad del archivo auditado verificada contra digest; mix check327 PASS seed371590.
