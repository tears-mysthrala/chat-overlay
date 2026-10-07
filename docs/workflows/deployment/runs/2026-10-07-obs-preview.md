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

Despliegue y prueba multimedia en OBS: pendientes, no acreditados por la subida #62.
