# ADR 0002: base de imagen — se mantiene Alpine 3.24.2 tras comparar alternativas

- Fecha: 2026-09-21. Aprobación del cambio de alcance evaluado: Kalista.
- Issue: #4 (gate de imagen). Rama: `feat/3-f1-overlay`.

## Contexto

El gate `image-security` falla con 4 coincidencias en Alpine 3.24.2
(CVE-2026-85091 en zlib 1.3.2-r0; CVE-2025-60876 en busybox 1.37.0-r31 ×3).
Se evaluó cambiar de distribución antes que convivir con Alpine vulnerable.

## Opciones medidas (mismo escáner pineado del proyecto, syft 1.52.0 + grype 0.119.0, más smoke real del release)

| Base | Resultado |
| --- | --- |
| Alpine 3.24.2 (actual) | 4 coincidencias, 2 CVE. Sin revisión corregida en rama estable (edge corrige busybox vía 1.38 pero no zlib; upstream zlib sin tag 1.3.3). |
| Rocky 9 | Descarta en smoke: el ERTS compilado en bookworm (GCC 12) exige `GLIBCXX_3.4.30`, EL9 trae GCC 11. |
| UBI 10 minimal | glibc OK pero el NIF `crypto` no carga: RHEL recorta SM4 de OpenSSL (`EVP_sm4_cbc` ausente) y todo OTP precompilado fuera de RHEL falla igual. Además la base mínima puntúa **202 coincidencias** (p. ej. util-linux High). Peor que Alpine. |
| Fedora 43 | Mismo muro SM4 que RHEL (Fedora también lo recorta): `crypto` no carga. |
| SLES 15-SP6 | glibc, libstdc++ y SM4 compatibles, pero el ERTS exige `strfnames, NCURSES6_TINFO_5.0.19991023` y el ncurses 6.1 de SUSE no exporta ese nodo: `beam.smp` no arranca. |
| Debian/Ubuntu slim | Arrancarían, pero Ubuntu marca zlib vulnerable con fix deferred en TODAS las releases y confirma que **a 2026-09-11 no existe parche upstream** (el commit etiquetado no corrige el reproducer; el rango afectado real es incierto). El CVE persistiría. |
| Chainguard | Registro con autenticación (`Forbidden` anónimo): fricción en CI y nuevo proveedor de confianza. Descartado sin probar más. |
| openSUSE Leap 15.6 | Único técnicamente compatible (glibc 2.38, OpenSSL completo con SM4, zlib 1.2.13, sin busybox), pero Grype solo cubre SLES, no Leap: un cero sería ceguera del escáner, no limpieza. Peor garantía (SUP-04). |
| Compilar OTP desde fuente en UBI/Rocky | Viable en teoría (enlazaría el OpenSSL de RHEL), pero exige verificar checksums débiles (solo MD5/sigstore en el release), alarga cada build de CI y **seguiría en rojo** por el resto de RPMs (p. ej. util-linux en UBI). Reservado como último recurso. |

Conclusión: ninguna alternativa da un gate verde honesto; UBI lo empeora (4 → 202),
Leap lo falsearía y el CVE de zlib **no tiene parche upstream a día de hoy**, así que
cambiar de distro solo cambia qué CVEs se arrastran. Por eso el pre-push local
(`scripts/pre-push`) replica el gate pesado cuando cambia el empaquetado: feedback
rápido antes de subir, sin sustituir a la CI, que sigue siendo la puerta exigible.

## Decisión

Mantener `alpine:3.24.2` por digest con APK pineados exactos (política en el
Dockerfile). Los 4 hallazgos quedan como riesgo residual documentado con
análisis de aplicabilidad en `docs/dependencies.md`; su dispensa requiere
decisión explícita de Kalista (SUP-07), nunca supresión silenciosa.

## Consecuencias

- El gate `image-security` sigue rojo hasta corrección de Alpine o dispensa firmada.
- Re-chequeo de proveedor documentado; re-escaneo ante cualquier revisión nueva.
- GP: si Alpine publica corrección, el upgrade es solo un cambio de pin + rebuild + rescan.
