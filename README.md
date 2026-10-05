# Chat Overlay

Overlay unificado para Twitch y YouTube (Kick formalmente diferido por inestabilidad upstream), con vista transparente para OBS, panel de creador, capability tokens y módulo de alertas multimedia en Cloudflare R2. Construido sobre Elixir/OTP, Bandit, Mint y frontend estático; sin frameworks pesados, bots de escritura ni servicios de IA.

**Estado:** F2 en cierre de deuda técnica (issues [#32–#55](https://github.com/tears-mysthrala/chat-overlay/issues/55)). El cierre histórico de [#21](https://github.com/tears-mysthrala/chat-overlay/issues/21) documenta su candidata de entonces; no acredita los cambios posteriores ni los requisitos pendientes de aislamiento y cuarentena. Ver [estado y evidencia actual](docs/verification.md), [operación](docs/operations.md) y [plataformas](docs/platforms.md).

## Probar con mensajes sintéticos

Para levantar la demo con Docker Compose, genera primero una clave de cifrado local (mínimo 32 caracteres) y arranca el contenedor:

```sh
export CHAT_ENCRYPTION_KEY="$(openssl rand -hex 32)"
docker compose -p chat-overlay-demo up --build
```

O creando un archivo local `.env`:

```sh
echo "CHAT_ENCRYPTION_KEY=$(openssl rand -hex 32)" > .env
docker compose -p chat-overlay-demo up --build
```

> **Conservación de la clave y persistencia:** La clave `CHAT_ENCRYPTION_KEY` cifra los tokens y estados OAuth en reposo (AES-256-GCM). Si se vinculan cuentas o se persisten perfiles (`config/local-profiles.json`), es imprescindible conservar la misma clave entre reinicios para poder descifrar los datos persistidos. En entornos de producción y en la release en contenedor, el sistema falla de inmediato (*fail-closed*) si `CHAT_ENCRYPTION_KEY` no se define, está vacía, tiene menos de 32 bytes o coincide con la clave por defecto de desarrollo. Compose fallará con un mensaje explicativo si la variable no está definida.

Abre <http://127.0.0.1:4100/> para acceder al Panel de Creador o <http://127.0.0.1:4100/reader/demo> para la vista de lectura. Desde el panel puedes gestionar el enlace protegido de OBS Studio, probar las alertas de sonido con el reproductor integrado y simular la regeneración de tokens en caliente.

El overlay para OBS (`/overlay/demo?token=...`) requiere un capability token válido de 32 bytes; si se omite el token, el overlay responde 401 Unauthorized con una pantalla informativa amigable.

La demo copia la configuración inicial a un directorio privado en RAM. Las mutaciones autenticadas se pierden al recrear el contenedor. Docker puede presentar al servidor la IP del puente en vez de loopback: en ese caso el panel exige sesión y la demo sin OAuth se limita al lector. Para probar el panel sin credenciales, usa Mix en loopback. Para cuentas reales, monta un directorio persistente escribible en `/state`, conserva la clave y elimina el comando de copia de la demo; no montes el archivo destino individualmente, porque la persistencia lo reemplaza mediante rename.

Para detener la demo: `docker compose -p chat-overlay-demo down`.

Con Elixir 1.20.4 y OTP 29.1:

```sh
mix deps.get
mix check
CHAT_CONFIG=config/demo.json mix run --no-halt
```

PowerShell: `$env:CHAT_CONFIG='config/demo.json'; mix run --no-halt`. En ejecución local con Mix se permite la clave de desarrollo por defecto si `CHAT_ENCRYPTION_KEY` no se especifica. El puerto por defecto es 4100; `CHAT_PORT` permite otro puerto no privilegiado. El listener local se limita a loopback. El contenedor escucha internamente en todas sus interfaces, pero Compose publica únicamente en loopback.

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
