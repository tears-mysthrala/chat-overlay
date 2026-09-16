# Arquitectura F0

## Frontera actual

```text
mix run -> ChatOverlay.Application (Supervisor OTP sin hijos) -> ChatOverlay.phase/0
```

F0 no escucha red, no resuelve URLs, no conecta plataformas y no persiste datos. La aplicación es una semilla ejecutable para validar el toolchain y la trazabilidad sin abrir superficies prematuras.

## Límites previstos

Para F1 se separarán adaptadores de plataforma, normalización, estado del overlay, transporte web y representación. Esa separación se documentará en issues específicos antes de implementar conectores. No se introduce Phoenix, LiveView, Ecto, Redis, Kafka, Broadway, Node/npm ni framework frontend en F0.

## Operación F0

No hay puertos, volúmenes, secretos, cuentas ni servicios externos. La parada del proceso no deja datos durables. La imagen de ejecución y el endurecimiento de contenedor quedan pendientes de una entrega ejecutable con servidor.
