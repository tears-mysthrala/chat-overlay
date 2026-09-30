# Chat Overlay

Overlay unificado para Twitch y YouTube (Kick formalmente diferido por inestabilidad upstream), con vista transparente para OBS, panel de creador, capability tokens y módulo de alertas multimedia en Cloudflare R2. Construido sobre Elixir/OTP, Bandit, Mint y frontend estático; sin frameworks pesados, bots de escritura ni servicios de IA.

**Estado:** Fases F1 y F2 completadas y validadas en vivo en OBS Studio 32.2.2 y plataformas reales (Twitch y YouTube). Cierre de Fase F2 consolidado en issue [#21](https://github.com/tears-mysthrala/chat-overlay/issues/21). Consulta [verificación](docs/verification.md), [operación](docs/operations.md) y [plataformas](docs/platforms.md).

## Probar con mensajes sintéticos

```sh
docker compose -p chat-overlay-demo up --build
```

Abre <http://127.0.0.1:4100/> para acceder al Panel de Creador o <http://127.0.0.1:4100/reader/demo> para la vista de lectura. Desde el panel puedes gestionar el enlace protegido de OBS Studio, probar las alertas de sonido con el reproductor integrado y simular la regeneración de tokens en caliente.

El overlay para OBS (`/overlay/demo?token=...`) requiere un capability token válido de 32 bytes; si se omite el token, el overlay responde 401 Unauthorized con una pantalla informativa amigable.

Para detener la demo: `docker compose -p chat-overlay-demo down`.

Con Elixir 1.20.4 y OTP 29.1:

```sh
mix deps.get
mix check
CHAT_CONFIG=config/demo.json mix run --no-halt
```

PowerShell: `$env:CHAT_CONFIG='config/demo.json'; mix run --no-halt`. El puerto por defecto es 4100; `CHAT_PORT` permite otro puerto no privilegiado. El listener local se limita a loopback. El contenedor escucha internamente en todas sus interfaces, pero Compose publica únicamente en loopback.

## Configuración y Perfiles de Creador

Los perfiles se configuran mediante JSON (`CHAT_CONFIG`). Cada perfil soporta:
- Conectores de chat: Twitch (Helix + EventSub WebSocket) y YouTube (Data API v3 con autodescubrimiento y soporte multistream).
- Capability Tokens: Hash SHA-256 en reposo y verificación en tiempo constante. Los enlaces de OBS se regeneran de forma atómica en caliente vía API o panel sin reiniciar el servidor.
- Módulo multimedia: URLs externas (validadas contra SSRF) o subidas directas a Cloudflare R2 vía URLs prefirmadas SigV4 generadas en Erlang/OTP nativo (*Zero Server Footprint / Zero Egress Fees*).
  - Variables de entorno opcionales: `R2_ENDPOINT`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_PUBLIC_CDN`.
  - Seguridad estricta: Bloqueo determinista de archivos `.svg` para proteger Chromium/CEF en OBS Studio contra XSS.

Los tokens de plataformas se inyectan en ejecución mediante variables de entorno `CHAT_*`; el JSON contiene los nombres de las variables, nunca los valores en plano. No incluyas secretos en URLs, commits o capturas.

## Validación y Auditoría de Seguridad

```sh
mix check
python3 scripts/security_static.py
python3 scripts/check_traceability.py
python3 scripts/scan_secrets.py
docker build --target validation -t chat-overlay:validation .
docker run --rm --network none --cpus 2 --memory 1g -e ERL_FLAGS='+S 2:2' chat-overlay:validation mix run --no-start scripts/load.exs 30
```

Documentación detallada en:
- [Arquitectura](docs/architecture.md)
- [Contrato de Eventos](docs/event-contract.md)
- [Modelo de Amenazas](docs/threat-model.md)
- [Operación](docs/operations.md)
- [Dependencias](docs/dependencies.md)
- [Cumplimiento](docs/compliance.md)
- [Verificación y Evidencias](docs/verification.md)
- [Handoff](docs/agent-handoff.md)

El historial de chat vive exclusivamente en memoria (RAM), con un límite estricto de 100 mensajes y 30 minutos por perfil. Un reinicio purga el historial. La recuperación SSE ofrece replay acotado o reset/snapshot consistente.
