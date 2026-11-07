# Reconstrucción del decoder candidato — 2026-11-07

Refs #50. Base `c016c06`, dependiente de la rama `fix/46-ci-build-recovery` (PR #84). Punto 2 de la decisión
humana del 2026-11-07: el decoder **no** está aprobado. Ni declaraciones VEX ni fechas nuevas ni
publicación de artefactos.

## Cambio

`zlib` y `zlib-dev` de la receta candidata pasan de 1.3.2-r1, retirado del índice de v3.24, a 1.4-r0, para
que vuelva a construir. `Dockerfile.media-validator` y las aprobaciones de `docs/security` no cambian.

## Quitar SQLite

Como paquete no es posible: el `python3` de Alpine depende de `so:libsqlite3.so.0`, y apk rechaza
`!sqlite-libs`. Sus archivos sí se pueden borrar tras instalarlo: solo `_sqlite3` enlaza la librería, y
una imagen derivada sin ellos pasó las cinco suites en la comprobación de QA. El escáner seguiría
listando el paquete. No se aplica aquí: queda como opción para la decisión humana.

## Resultados en este host

| Comprobación | Resultado |
| --- | --- |
| Build de la receta candidata | PASS |
| Regresiones de los parches de Python, sin caché | 8 PASS |
| Cinco suites del decoder con la imagen nueva | PASS |
| Auditoría de candidata, sin VEX | **Falla por diseño**: 17 coincidencias, las mismas que el candidato anterior |

El dossier local repetido sobre esta imagen exacta queda para la próxima decisión humana. Ninguna
coincidencia es nueva.

## Límites

No probado en el runner ni en CI. La rama de release de este repositorio todavía tiene el pin antiguo
de `zlib` en `Dockerfile`; lo corrige la PR del release (#88), así que image-security fallará aquí hasta
entonces. Rollback: revert.
