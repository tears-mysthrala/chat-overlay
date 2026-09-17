# chat-overlay

Fundamento F0 de un overlay de chat autoalojado. Esta entrega solo establece una aplicación Elixir/OTP mínima y documentación trazable; no es un lanzamiento ni implementa conectores.

## Requisitos

- Elixir `~> 1.17`
- Erlang/OTP compatible con esa versión de Elixir

## Arranque y pruebas

```text
mix deps.get
mix check
mix run --no-halt
```

`mix check` verifica formato y pruebas. La aplicación no abre puertos en F0.

## Estado y límites

- F0 únicamente; no hay cuentas, bots, runners, conectores reales, almacenamiento ni secretos.
- Solo se prevén datos sintéticos en pruebas.
- La validación en vivo de Twitch, YouTube y Kick requiere issues separados y autorización.

Consulta `docs/agent-handoff.md` para el estado de la entrega y `docs/verification.md` para la evidencia.
