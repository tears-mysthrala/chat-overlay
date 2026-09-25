# Operación local y preparación de publicación

## Arranque, parada y actualización

Usar Compose para la demo local o construir `docker build -t chat-overlay:<revision> .`. No publicar el puerto en interfaces externas antes de superar los gates. La configuración se monta como solo lectura; no hay volumen de historial. `/health/live` confirma listener y `/health/ready` comprueba stores: no certifica conectividad upstream.

La imagen corre como UID/GID 65532. Compose elimina capacidades, impide nuevos privilegios, limita CPU a 2, memoria a 1 GiB y PID a 128, monta raíz de solo lectura y `/tmp` acotado. Desactiva distribución Erlang y vuelcos de crash a disco. La VM tiene dos schedulers y límites explícitos de procesos/puertos. No montar socket Docker, directorios del host o credenciales de otras aplicaciones.

Para actualizar: conservar configuración y referencias secretas fuera de Git, construir y probar un nuevo digest, comparar SBOM/avisos, detener la instancia anterior y arrancar la nueva con los mismos límites. Rollback: restaurar el digest anterior aprobado y su configuración. No hay migraciones; cualquier reinicio pierde historial y obliga a un snapshot nuevo. Rotar tokens cambiando el entorno y reiniciando la instancia; no imprimirlos ni pasarlos como argumentos de CLI.

## Acceso y observabilidad

El operador debe mantener TLS, proxy sin buffering SSE, segmentación y límites de conexión/rate a la entrada. Las IP reenviadas no son identidad. No hay log de contenido de chat ni tokens; los estados públicos omiten detalles de credenciales y errores upstream. Los mensajes se retienen hasta 30 minutos/100 por perfil. Reiniciar también purga dedup y barreras; no se recupera contenido durable.

La demo no requiere credenciales. Para vivo, seguir [platforms.md](platforms.md). No conectar Kick al callback local mediante un túnel real como parte de esta PR: requiere una publicación autorizada.

## Vulnerabilidades y gates

[SECURITY.md](../SECURITY.md) identifica el canal privado real y a Kalista como responsable. Conservar versión/digest, alcance y evidencia sin secretos; reproducir en aislamiento, corregir y repetir pruebas. El responsable decide distribución, comunicaciones y cualquier obligación de notificación; verificar normativa vigente al activar un incidente. No hacer notificaciones automáticas a terceros.

Antes de piloto público: cerrar hallazgos de imagen, revisión humana, tres plataformas desde servidor previsto, OBS real, carga de 4 h y de 24 h, condiciones de plataforma y matriz normativa, contacto/soporte, firma y verificación del artefacto. No se ha realizado merge, despliegue, registro de apps, DNS o túnel.
