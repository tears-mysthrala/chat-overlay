# Recuperación de CI — 2026-11-05

Refs #46, #50. Base `2f26827`. Autorizado por el propietario: diagnosticar y corregir CI
solo en este repositorio, sin merge, despliegue ni producción. No acredita producción.

## Causa inicial por job

Runs [41474962609](https://github.com/tears-mysthrala/chat-overlay/actions/runs/41474962609)
(main) y 42128274996 (PR #83). Un job que se detiene oculta sus etapas posteriores.

| Job | Primer fallo | Sin ejecutar |
| --- | --- | --- |
| source-and-tests | `mix hex.audit` detiene el build | ExUnit, recuperación, navegador, carga |
| postgres-rls | La misma auditoría; la falta de informes es consecuencia | Migración, RLS, reinicio |
| image-security | Pin APK `ca-certificates` retirado | Smoke, aislamiento, SBOM, escaneo |
| media-decoder | Pin APK `python3` retirado | Pruebas, artefacto histórico, auditoría |
| quality-gate | Falla correctamente por las cuatro dependencias | No requiere cambios |

Ocultos y encontrados al avanzar: pin `musl-dev` de `Dockerfile.recovery-faults`; hallazgos con
corrección en Elixir, OTP, `musl` y `zlib`; vencimiento de las revisiones VEX (21-10-2026);
y la auditoría final de media-decoder retiquetaba el artefacto histórico, sin cubrir lo construido.

## Cambio

Ver [dependencias](../../../dependencies.md). `Dockerfile.media-validator` y las aprobaciones de
`docs/security` no cambian. La auditoría de candidata no aplica VEX: todo hallazgo falla.
El cambio de `.github/workflows/ci.yml` requiere una credencial con permiso `workflow`.

## Resultados locales en `eb47460`

VM ~3,5 GiB, en serie, con límites de CI. SELinux obligó a desactivar etiquetas de montaje en
Docker mediante un envoltorio local no versionado. Datos sintéticos.

| Comprobación | Resultado |
| --- | --- |
| `mix hex.audit`, formato, compilación con warnings como errores | PASS |
| ExUnit, seeds 0 y 424242 | 329 PASS en cada una; validador de informes PASS |
| ENOSPC, EIO, SIGKILL durante staging | PASS |
| Carga sintética 30 s | 0 errores |
| PostgreSQL/RLS, seeds 0 y 424242 | 26 PASS en cada una; arranque, mutación y reinicio PASS |
| Build, smoke y aislamiento de dos releases | PASS |
| Auditoría de imagen | **Falla**: VEX vencido antes de escanear. Escaneo sin VEX: solo BusyBox, sin corrección publicada |
| Decoder candidato: build, regresiones Python, cinco suites | PASS. Los ID de imagen cambian entre builds: una aprobación debe ligar un artefacto publicado, no la receta |
| Auditoría de decoder candidato | **Falla**: 17 coincidencias: 4 altas, 11 medias, 2 bajas |
| Artefacto histórico: tar verificado y cinco suites | PASS con el ID local de este host (`8274808e`) |
| Auditoría aprobada del histórico (QA, `03904f7`, imagen `8274808e`) | **Falla**: ID de imagen distinto aquí; con la identidad aprobada, revisión vencida |
| `scan_secrets.py` | Falla en este host con SELinux y etiquetas de montaje activas; PASS sin fugas solo con esas etiquetas desactivadas |
| Estática, VEX normal/-O, pruebas auxiliares | PASS |

Navegador: `ci_browser.sh` PASS en escritorio y móvil, en ejecución local adaptada con la imagen
Playwright 1.63.0 fijada (QA, `03904f7`), no el paso del runner. No ejecutado: CI remota. Las
comprobaciones previas con Elixir 1.20.4 no cuentan para esta candidata.

## CI remota en `50c38fe`

[Run 42185602110](https://github.com/tears-mysthrala/chat-overlay/actions/runs/42185602110), 06-11-2026.
Sustituye las predicciones anteriores para esa revisión. source-and-tests y postgres-rls: PASS,
incluidos secretos y navegador en el runner. image-security: falla por el VEX vencido, tras smoke y
aislamiento PASS. media-decoder: pruebas de candidata e histórico PASS; el tar cargó con el ID
aprobado `89432cb3`; fallan ambas auditorías. quality-gate: falla correctamente.

## Puertas humanas

1. image-security: decidir la declaración BusyBox para la imagen nueva (#50).
2. media-decoder: decidir aprobación y publicación de un artefacto nuevo (#50).
3. Publicar el cambio de workflow con una credencial autorizada.

Hasta entonces image-security, media-decoder y quality-gate siguen en rojo: esta unidad es una
recuperación parcial. Rollback: revert; no toca datos ni producción.
