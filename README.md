# Chat Overlay

Overlay de solo lectura para Twitch, YouTube y Kick, con vista transparente para OBS y lector para el creador. Elixir/OTP, Bandit, Mint y frontend estático; sin cuentas, bots, base de datos ni servicios de IA.

**Estado:** implementación F1 en revisión, issue [#3](https://github.com/tears-mysthrala/chat-overlay/issues/3). Las plataformas no están validadas en vivo. No es una versión autorizada para publicar. Consulta [verificación](docs/verification.md) y [hallazgos](docs/dependencies.md).

## Probar con mensajes sintéticos

```sh
docker compose -p chat-overlay-demo up --build
```

Abre <http://127.0.0.1:4100/reader/demo>. El botón «Abrir overlay» muestra la vista transparente, también accesible en `/overlay/demo`. La demo está rotulada y no contacta plataformas. Para detenerla: `docker compose -p chat-overlay-demo down`.

Con Elixir 1.20.4 y OTP 29.1:

```sh
mix deps.get
mix check
CHAT_CONFIG=config/demo.json mix run --no-halt
```

PowerShell: `$env:CHAT_CONFIG='config/demo.json'; mix run --no-halt`. El puerto por defecto es 4100; `CHAT_PORT` permite otro puerto no privilegiado. El listener local se limita a loopback. El contenedor escucha internamente en todas sus interfaces, pero Compose publica únicamente en loopback.

## Configuración real

Los perfiles son públicos y los aprovisiona el operador mediante JSON. No hay alta pública ni directorio de perfiles. Los tokens se inyectan solo en ejecución mediante variables `CHAT_*`; el JSON contiene los nombres de las variables, nunca los valores. No incluyas secretos en URLs, commits o capturas.

[Guía de plataformas](docs/platforms.md): registro, identificadores estables, permisos mínimos y límites. `gilraennr` es la referencia facilitada por el operador; no se ha acreditado la correspondencia de IDs ni titularidad. Las aplicaciones/API todavía no están registradas.

Cada perfil admite hasta tres fuentes. `overlay_platforms` permite separar las plataformas mostradas en la emisión de las mostradas en el lector. Esto no convierte al lector en privado: ambas rutas son públicas. Antes de emitir, comprueba las condiciones de cada plataforma.

## Validación y operación

```sh
mix check
python scripts/security_static.py
python scripts/check_traceability.py
docker build --target validation -t chat-overlay:validation .
docker run --rm --network none --cpus 2 --memory 1g -e ERL_FLAGS='+S 2:2' chat-overlay:validation mix run --no-start scripts/load.exs 30
```

[Arquitectura](docs/architecture.md), [eventos](docs/event-contract.md), [amenazas](docs/threat-model.md), [operación](docs/operations.md), [dependencias](docs/dependencies.md), [cumplimiento](docs/compliance.md) y [handoff](docs/agent-handoff.md).

El historial vive en memoria, con un máximo de 100 mensajes y 30 minutos por perfil. Un reinicio lo pierde. La recuperación SSE ofrece replay acotado o reset/snapshot; no garantiza entrega exactamente una vez ni recuperación de borrados que el proveedor no expone. Kick no ofrece en el contrato oficial utilizado un evento de borrado individual.
