# Incorporación del contrato a chat-overlay

Coloca `WHAT_WE_ARE_BUILDING.md` y `AGENTS.md` en la raíz de tu carpeta `chat-overlay`, y `copilot-instructions.md` dentro de `.github/`. El ZIP ya contiene esa estructura. Si alguno existe, compara e integra el contenido; no sobrescribas cambios propios.

No contiene aplicación, credenciales, issues creados ni despliegues. El hostname es el previsto en el diseño; no se ha verificado ni configurado desde este paquete. El agente debe descubrir el repositorio real y aplicar el procedimiento de bootstrap.

## Mensaje inicial para el agente

```text
Lee AGENTS.md y WHAT_WE_ARE_BUILDING.md. Trabaja únicamente en F0.

Comprueba la carpeta, los cambios existentes, origin, la rama predeterminada y el acceso a GitHub. No asumas que ya existe el repositorio ni lo crees sin mi aprobación. Si falta un requisito, indica exactamente cuál y no implementes funcionalidades sin issue remoto.

Busca un issue de bootstrap existente o crea uno real para la necesidad F0. Resume su alcance y criterios de aceptación. Crea su rama y worktree independiente antes de modificar el proyecto. Incorpora el contrato y configura una base mínima ejecutable con el workflow trazable y pruebas, siguiendo el documento.

No construyas todas las fases. Entrega una primera PR pequeña y verificable, con el número del issue, evidencia de lo probado y pendientes explícitos. No hagas merge, no conectes cuentas privadas ni despliegues producción. Finaliza con el handoff requerido.
```

Las instrucciones en archivos orientan al agente; los checks de CI, protecciones del repositorio y revisión humana deben implementarse para reforzarlas. Los archivos no activan esos controles por sí mismos.

Referencias de los puntos de entrada: documentación de [AGENTS.md](https://developers.openai.com/codex/guides/agents-md) y de [instrucciones de repositorio para Copilot](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/add-custom-instructions/add-repository-instructions).
