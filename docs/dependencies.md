# Dependencias y cadena de suministro — issue #3

La sustitución por Bandit/Mint fue aprobada expresamente por Kalista el 20-09-2026. [ADR 0001](adr/0001-transporte-f1.md) recoge alternativas y motivo. No se reutilizó código de los forks Chatterino: sus implementaciones no forman parte del artefacto nuevo.

## Producción

| Componente fijado | Papel | Licencia de paquete |
| --- | --- | --- |
| Elixir 1.20.4 / OTP 29.1 | Runtime, JSON, OTP, TLS y criptografía | Apache-2.0; conservar avisos de runtime |
| Bandit 1.12.5 | Servidor HTTP | MIT |
| Mint 1.10.1 | HTTP/TLS saliente | Apache-2.0 |
| Mint.WebSocket 1.0.6 | Protocolo WebSocket | Apache-2.0 |
| hpax 1.0.4 | Dependencia de transporte | Apache-2.0 |
| mime 2.0.7 | Tipos MIME de Plug | Apache-2.0 |
| Plug 1.20.3 / plug_crypto 2.2.0 | Contrato web / primitivas de Plug | Apache-2.0 |
| telemetry 1.4.2 | Instrumentación interna de dependencias | Apache-2.0 |
| Thousand Island 1.5.0 / websock 0.5.3 | Conexiones / contrato WebSocket de Bandit | MIT |

Son diez paquetes Hex directos/transitivos, todos fijados con hashes en mix.lock. El script de inventario valida metadatos/licencias y copia sus textos a `/app/share/licenses`. Mint.WebSocket omite LICENSE en su paquete Hex; se incorpora sin cambios desde el commit de su tag v1.0.6 `302eb21d6ecf2a21c85ae4392f922ae5f6cb8fc2`, en `vendor/licenses/`. No hay NIF añadida por estos paquetes. OTP incluye código nativo y enlaza bibliotecas de la imagen (musl, OpenSSL, zlib, libstdc++, ncurses), inventariadas por Syft.

La imagen y builder Alpine 3.24.2 están fijados por digest en Dockerfile. Los repositorios APK firman paquetes, pero sus revisiones pueden actualizarse al reconstruir: **no se afirma reproducibilidad bit a bit**. El inventario y el escaneo se ligan al digest construido. El runtime no instala paquetes, descarga código ni compila al arrancar. La imagen no incluye herramientas de build o scanners.

Los paquetes pueden ejecutar sus tareas de compilación durante el build, en un entorno sin secretos de producción. En ejecución, los permisos son los del UID 65532; ninguna dependencia obtiene privilegios extra. No hay exportador de telemetría configurado. Retirada: transporte detrás de Net/Socket/Web/Stream; cambiar componentes exige ADR, pruebas de protocolo y nueva aprobación cuando corresponda.

## Herramientas y cobertura

Rebar 3.25.1 se descarga desde Hex con URL/version y SHA-512 fijados en Dockerfile. Hex 2.5.1 audita también avisos de seguridad. Hex 2.4.2 local solo produjo el informe de paquetes retirados y **no se tomó como evidencia de seguridad**. El árbol nuevo pasó la auditoría de Hex 2.5.1 sin retirados ni avisos.

Syft 1.52.0 genera CycloneDX 1.7 de la imagen; su catálogo no detectó paquetes Hex, por lo que `scripts/inventory.exs` los añade con versiones, licencias, hashes y relaciones. `scripts/audit_image.py` integra aplicación y runtime, valida contra el esquema oficial fijado al commit `4b3f59453366e27c8073fd24e98bf21ef8892c8e` y ejecuta Grype 0.119.0 con base actualizada. Scanners por digest, sin socket Docker dentro de ellos. Artefactos grandes se guardan en `output/audit/` y en CI durante 14 días; no se suben imágenes ni chats a un registro.

Gitleaks 8.30.1 escanea la instantánea de fuente que Git considera versionada/versionable, con redacción; no examina secretos locales ignorados ni pretende certificar todo el historial Git. `security_static.py` detecta algunas construcciones prohibidas, no sustituye una revisión completa. jsonschema 4.26.0/referencing 0.37.0 son herramientas de validación, no dependencias del servicio.

## Hallazgos abiertos: 4 coincidencias, 2 CVE

| Paquete | Aviso | Severidad de Grype | Estado |
| --- | --- | --- | --- |
| zlib 1.3.2-r0 | CVE-2026-85091 | High | Sin versión corregida indicada por el escáner |
| busybox 1.37.0-r31 | CVE-2025-60876 | Medium | Abierto |
| busybox-binsh 1.37.0-r31 | CVE-2025-60876 | Medium | Misma implementación BusyBox |
| ssl_client 1.37.0-r31 | CVE-2025-60876 | Medium | Mismo paquete fuente BusyBox |

La primera afecta a operaciones gzwrite/gzprintf de zlib; la segunda a wget de BusyBox. El servidor usa Mint y no invoca wget o shell para chat, pero eso **no es una corrección del componente ni una aceptación humana del riesgo**. Los resultados se mantienen íntegros, sin supresión/VEX que los oculte. El gate de imagen falla con cualquier hallazgo, incluidos Unknown/Negligible. No se declara CI global verde ni autorización de publicación.

Fuentes primarias: [NVD BusyBox](https://nvd.nist.gov/vuln/detail/CVE-2025-60876), [registro CNA de zlib](https://www.vulncheck.com/advisories/zlib-1.3.1.2-through-1.3.2-heap-buffer-overflow-via-gz-vacate), [Alpine seguimiento](https://github.com/alpinelinux/docker-alpine/issues/480). Revisar nuevas revisiones de proveedor y repetir el escaneo antes de cerrar estos bloqueos. No se mantiene un fork de la distribución ni se atribuye explotabilidad concreta al overlay sin evidencia.

SUP-05 sigue pendiente antes de distribución: firma/procedencia verificable y revisión de todas las obligaciones de licencia de la imagen. El SHA-256 identifica bytes; no autentica al publicador.
