# Inventario y decisión de dependencias F0

## Aplicación

- Elixir `~> 1.17`, runtime necesario para compilar y ejecutar.
- Erlang/OTP compatible, runtime necesario para la VM.
- Dependencias Mix de producción: ninguna.

CI fija Elixir 1.20.4 y Erlang/OTP 29.0.6 mediante commits inmutables de las acciones. El árbol Mix está vacío en F0; cualquier dependencia futura deberá registrar finalidad, licencia, transitivas, mantenimiento, avisos, permisos y retirada.

## Decisiones

Se usa `Application` y `Supervisor` de OTP, sin framework web ni cliente de plataforma. Esto mantiene la superficie mínima de F0 y evita incorporar dependencias antes de su issue de finalidad, licencia, transitivas, mantenimiento, avisos, permisos y retirada.

## Pendiente

Generar SBOM CycloneDX o SPDX para el artefacto de entrega, registrar la herramienta/versión/hash y revisar licencias y avisos. Esto no se presenta como completado por tener un `mix.exs` sin dependencias.
