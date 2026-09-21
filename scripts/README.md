# Verificación local

Los scripts de esta carpeta son herramientas de desarrollo. No forman parte de la imagen final.
Ejecutar desde el worktree del issue. No utilizar datos o credenciales reales en pruebas de carga.

## Hook pre-push (obligatorio por clon)

Instalar una vez por clon con `scripts/install-hooks.sh`. Antes de cada push ejecuta:
formato, trazabilidad, secretos y estática siempre; `mix check` en cambios normales;
build + smoke + auditoría de imagen (SBOM/Grype) cuando cambia el empaquetado
(`Dockerfile`, `mix.*`, `config/`, `lib/`, `priv/`, `vendor/`). Si falla, el push no
sale. Saltarlo (`--no-verify`) debe justificarse en la PR; la CI sigue siendo la
puerta exigible y no se puede saltar.
