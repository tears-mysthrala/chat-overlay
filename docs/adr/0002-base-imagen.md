# ADR 0002: base de imagen — se mantiene Alpine 3.24.2 tras comparar alternativas

- Fecha: 2026-09-21. Aprobación del cambio de alcance evaluado: Kalista.
- Issue: #4 (gate de imagen). Rama: `feat/3-f1-overlay`.

## Contexto

El gate `image-security` falla con 4 coincidencias en Alpine 3.24.2
(CVE-2026-85091 en zlib 1.3.2-r0; CVE-2025-60876 en busybox 1.37.0-r31 ×3).
Se evaluó cambiar de distribución antes que convivir con Alpine vulnerable.

## Opciones medidas (mismo escáner pineado del proyecto, syft 1.52.0 + grype 0.119.0)

| Base | Resultado |
| --- | --- |
| Alpine 3.24.2 (actual) | 4 coincidencias, 2 CVE. Sin revisión corregida en rama estable (edge corrige busybox vía 1.38 pero no zlib; upstream zlib sin tag 1.3.3). |
| Rocky 9 | Descargada: ERTS compilado en bookworm (GCC 12) no arranca (exige `GLIBCXX_3.4.30`, EL9 trae GCC 11). |
| UBI 10 minimal | Arranca glibc pero el NIF `crypto` de OTP no carga: RHEL recorta SM4 de OpenSSL (`EVP_sm4_cbc` ausente) y todo OTP precompilado fuera de RHEL falla igual. Además, la imagen base mínima ya puntúa **202 coincidencias** con nuestro escáner (p. ej. util-linux High). Peor que Alpine. |
| Debian/Ubuntu slim | Mantienen zlib 1.3.x, dentro del rango afectado: el CVE seguiría apareciendo. |
| Chainguard | Registro con autenticación (`Forbidden` anónimo): fricción en CI y nuevo proveedor de confianza. Descartado sin probar más. |
| openSUSE Leap 15.6 | Compatible en toolchain (glibc 2.38, OpenSSL completo con SM4, zlib 1.2.13, sin busybox), pero Grype solo cubre SLES, no Leap: un cero sería ceguera del escáner, no limpieza. Peor garantía (SUP-04). |
| Compilar OTP desde fuente en UBI/Rocky | Viable en teoría (enlazaría el OpenSSL de RHEL), pero exige verificar checksums débiles (solo MD5/sigstore en el release) y alarga cada build de CI. No se adopta sin necesidad. |

Conclusión: ninguna alternativa da un gate verde honesto; UBI lo empeora (4 → 202) y Leap lo falsearía.

## Decisión

Mantener `alpine:3.24.2` por digest con APK pineados exactos (política en el
Dockerfile). Los 4 hallazgos quedan como riesgo residual documentado con
análisis de aplicabilidad en `docs/dependencies.md`; su dispensa requiere
decisión explícita de Kalista (SUP-07), nunca supresión silenciosa.

## Consecuencias

- El gate `image-security` sigue rojo hasta corrección de Alpine o dispensa firmada.
- Re-chequeo de proveedor documentado; re-escaneo ante cualquier revisión nueva.
- GP: si Alpine publica corrección, el upgrade es solo un cambio de pin + rebuild + rescan.
