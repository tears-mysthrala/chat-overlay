# Preview manual #64

Autorización explícita del propietario en esta conversación: implementar el nuevo
evento manual y probar/desplegar en Benten/OBS. Rama feat/64-obs-preview, base
9a71844 (almacenamiento local #62). Sin nuevas dependencias ni eventos de plataformas.

POST autenticado con sesión del perfil, origen autorizado y JSON cerrado vacío.
Autorización y selección de objetos activos se repiten en el escritor serializado.
Solo PNG/WAV normalizados del inventario local del mismo perfil. Cooldown10s,
un evento por Store, caducidad10s; fuera del ring y snapshot. Cada nueva conexión
adopta el cursor actual para descartar previews anteriores. El lector no recibe
preview; el overlay vuelve a verificar capability y selección activa antes de enviar.

Validación local: formato, compilación con warnings-as-errors y sintaxis JavaScript
PASS; suite completa 295 PASS en la imagen validation a5182323, incluidas cinco
regresiones de la unidad y entrega HTTP/SSE real al overlay con omisión del lector
y reconexión. Runtime construido 43ed8a7ac203fd6cb13017b4e41d11e45871eca223abd4d4e4e5f0ad2e1987d3.
SBOM CycloneDX1.7 válido, 295 componentes; escaneo de imagen en curso.

Revisión oficial OpenAI Codex Security e28c1e39-f15d-477c-a74d-ede033a1aec8
completada sobre 9a71844..ffc0161: ocho fuentes, sin vulnerabilidades reportables.
Arquitectura independiente GPT-6.1-Sol offline reconciliada. Corrección documental:
la selección se revalida antes del envío, sin invalidación irreversible del mapa;
el último mapa caducado queda acotado en memoria hasta sobrescritura/reinicio.
Los archivos normalizados publicados son públicos por URL; el evento es protegido.
El fallback sin escritor registrado no serializa, pero la supervisión normal inicia
Profiles registrado. ARCH06 y mantenimiento de inventario son deuda heredada separada.

Grype runtime: cero hallazgos activos, cuatro cubiertos por VEX aprobado vigente.
Desplegado digest43ed8a7a en Benten9502 con backup privado
/var/lib/chat-overlay/backups/preview-64-ffc0161: compose/runtime.env/pg_dump.
No se cambiaron datos, tokens, coordinator, firewall ni túnel. Readiness y POST
anónimo403 PASS. App65532:65532/rootfs readonly; coordinador systemd sigue activo.
Sesión renovada por OAuth Twitch existente sin ampliar scopes.

Panel real: botón devuelve prueba enviada. OBS32.2.2: emote PNG mostrado en fuente
protegida; captura output/obs/preview-observed.png. Refreshnocache inmediatamente
tras observar la imagen; captura3s después output/obs/preview-reconnected.png
completamente transparente, sin replay mientras el preview original aún caduca.
No streaming ni grabación activos. Los intentos iniciales de captura acabaron
antes del envío por latencia de herramientas; no se contaron como PASS. Chrome
CDP presentaba timeout antes de dispatch en pestañas reutilizadas; nueva pestaña
y acción/observación en una llamada completaron envío, sin duplicar a ciegas.
Audio audible: confirmado explícitamente por el operador en esta conversación.
Es validación comunicada por el usuario, no medición instrumental. Revocación de capability
actual: propietario regeneró el enlace; refresh real de la fuente antigua mostró
401 No Autorizado. Captura output/obs/revoked.png: revocación real PASS.
Recuperación con enlace nuevo PASS: propietario lo pegó en la fuente de la escena
activa InGame Scene. Se detectaron dos fuentes del proyecto: Browser en escena Chat
con enlace viejo y fuente activa con enlace nuevo. Se seleccionó únicamente la
fuente habilitada de la escena activa, sin modificar escenas ni otras fuentes.
Preview nuevo mostró PNG; captura output/obs/preview-newlink-observed.png. Refresh
inmediato produjo captura transparente output/obs/preview-newlink-reconnected.png,
sin replay. No streaming/grabación. La fuente antigua se conservó, ya revocada.
Prueba local de sesión revocada PASS.
CI, publicación/merge y deuda operativa siguen separados.

PR #65 publicada desde feat/64-obs-preview. CI remoto 37648370619:
postgres-rls falló al escribir /evidence/postgres-0.json (permission denied).
La imagen de validación ejecuta root sin capabilities; el bind mount era del
runner y no permite bypass DAC. Se asigna solo output/postgres a UID/GID 0 en CI,
sin cambiar usuario ni capabilities del contenedor ni producción. Escritura con
ALL capabilities eliminadas y no-new-privileges comprobada localmente PASS.
El resultado RLS remoto sigue pendiente hasta la siguiente ejecución.
Codex cloud revisando 7834a91; CodeRabbit omitido por tamaño/capacidad y Copilot
omitido por cuota. Ninguna omisión se considera aprobación.

Codex cloud sobre 7834a91 señaló dos P1 de reproducibilidad del despliegue:
pin antiguo en Compose y ausencia de la regla input del coordinador en harden.sh.
Ambos confirmados. Lectura SSH verificada de Benten: runtime43ed8a7a,
egress172.30.96.2 y regla exacta peer172.30.96.2 -> host172.30.96.1:4199
ya activos. Se concilian los archivos versionados con ese estado, incluyendo IP
estática en Compose. No se reejecuta provisionado ni firewall en producción.
