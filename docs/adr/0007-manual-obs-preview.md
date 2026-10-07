# ADR 0007: preview manual de multimedia en OBS

Estado: aprobado explícitamente por Kalista el 07-10-2026 en esta conversación;
Refs #64. La aprobación cubre el evento nuevo, implementación y pruebas en Benten/OBS.

La subida local #62 activa archivos pero la prueba de sonido del panel reproduce
solo en el navegador del creador. Se necesita probar la representación real en OBS.

Se añade POST de sesión del propietario con origen exacto y JSON vacío. El escritor
serializado revalida autorización y selecciona solo objetos PNG/WAV locales activos
del mismo perfil. Exige capability configurada; no acepta URLs ni payload de usuario.
Store conserva un único preview temporal con cooldown de 10 segundos. El SSE separado
media_preview nunca entra en replay/snapshot y cada conexión inicia desde el cursor
actual. Antes de enviar, se revalidan capability y selección activa. El cliente solo
acepta rutas normalizadas del mismo perfil, deduplica 32 IDs, detiene reproducción
al desconectar y caduca a los 10 segundos, con volumen 35%.

No garantiza recepción en un overlay desconectado ni reproducción audible si el
navegador/OBS bloquea audio. No añade bots, follows/subs, escritura en plataformas,
dependencias ni retención durable. Reiniciar Store reinicia el cooldown; no hay
garantía de entrega exactamente una vez. Un cambio de archivos descarta el preview
pendiente y un archivo retirado deja de servirse por el endpoint local.
