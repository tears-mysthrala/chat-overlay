# Despliegue Benten — Refs #55

1. Confirmar autorización, revisión/worktree limpio, quorum/capacidad y guest
   dedicado. No instalar aplicaciones en Proxmox ni reutilizar guests MKDL/banca.
2. Construir release y ligar smoke, inventario/SBOM/escaneo al digest exacto.
   Actualizar pins ante avisos; no extrapolar un resultado del builder al runtime.
3. Crear guest desde imagen verificada con clave pública del operador. Obtener
   su host key por el canal QEMU/Benten verificado y usar known_hosts dedicado.
   Enviar scripts por stdin como bytes LF; no convertirlos a text CRLF.
4. Usar `deploy/benten/compose.yaml` y provisionado inicial privado en el guest.
   No repetir provisionado: conservar clave de cifrado, CA, contraseñas y datos.
   PostgreSQL requiere TLS/SNI/CA verificada y roles separados con FORCE RLS.
5. Restricciones del guest mediante `deploy/benten/harden.sh`: SSH de operador/
   Benten, puertos Docker privados, sin socket Docker en backend/decoder. No
   reejecutar nftables sin conciliar su tabla existente. No flush global del host.
6. En una instalación vacía, ejecutar smoke persistencia sin clientes activos;
   parar el único coordinador antes de cada operación offline. Comprobar
   eliminación del perfil sintético. Redirigir stdin de comandos Docker que no
   lo necesiten para que no consuman el resto del script enviado por SSH.
7. Guardar dump/estado con modo 0600, checkpoint con ambos servicios detenidos
   y verificar readiness tras reinicio del guest. Copias en el mismo host no
   constituyen backup externo; restore requiere verificación separada.
8. Leer configuración efectiva del túnel con `cf` autorizado, guardar baseline
   y preservar reglas existentes. Solo entonces aplicar el ingreso propuesto,
   ajustar firewall para el connector verificado y crear DNS si está libre.
   Un 401 no autoriza buscar credenciales alternativas. No rebajar verificaciones.
9. Validar HTTPS externo, proxy confiable, rechazo anónimo, cookies/callbacks y
   SSE. Aprovisionar OAuth/R2 con canales privados y ámbitos separados antes de
   afirmar que chats reales o multimedia funcionan. No reutilizar secretos de
   otros servicios. No promover originales ni habilitar media sin coordinador.
10. Rollback: retirar exclusivamente la ruta nueva, detener writers, conservar
    datos/journal y evaluar snapshot con requisitos de reconciliación. Una vez
    haya usuarios/escrituras, no restaurar indiscriminadamente un snapshot viejo.
