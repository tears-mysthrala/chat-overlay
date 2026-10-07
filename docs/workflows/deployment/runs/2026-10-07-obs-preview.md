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
PASS; suite294 PASS antes de añadir la prueba de transporte; cinco regresiones
de la unidad PASS, incluida entrega HTTP/SSE real al overlay y omisión del lector
y reconexión. Revisión oficial, build, despliegue y prueba multimedia en OBS:
pendientes, no acreditados por la subida del panel #62.
