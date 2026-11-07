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
una imagen derivada sin ellos pasó las cinco suites en la comprobación de QA. Se espera que el escáner siga
listando el paquete, pero esa variante no se escaneó. No se aplica aquí: queda como opción para la decisión humana.

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

## Aprobación condicionada — 2026-11-07

La persona titular aprobó el artefacto exacto del dossier con la condición de que el CI de la PR #89
pasara las suites del decoder sobre esta receta. En el run 42411237618 (`fc389f0`) la receta construyó, las
8 regresiones de Python y las cinco suites del decoder pasaron. Las dos auditorías fallaron como se
esperaba: aprobación anterior vencida, y la candidata sin VEX.

- **Artefacto publicado:** release `decoder-1200864a-20261107`, `decoder-1200864a.tar`, 27 260 928 bytes,
  SHA256 `701dd3cb…`. Es el tar de la imagen del dossier, no una reconstrucción; el SHA256 descargado
  coincide.
- **Ligadura:** `decoder-evidence.approved.json` liga el ID de config `1200864a…`, que es lo que un runner con
  almacén clásico informa, y registra índice, manifiesto, tar, hashes de fuente y de runtime.
  `Dockerfile.media-validator` pasa a ser la receta de este artefacto y sustituye a la histórica.
- **VEX:** 15 declaraciones cubren las 17 coincidencias. `not_affected` según los grupos del dossier
  (D1 por ausencia del CLI), D3 `fixed` ligado al hash de `poplib`, revisión el 2027-02-05. Aplicado al
  SBOM exacto: 0 activas, 17 cubiertas.
- **CI:** descarga y verifica ese tar y su ID. La auditoría de la receta reconstruida, sin VEX, se
  mantiene aparte y sigue fallando con las 17 coincidencias: una reconstrucción tiene otro ID. Si debe
  dejar de bloquear lo decide la persona.
- No se borran archivos de SQLite, por decisión.

Pendiente: comprobar en el runner que el tar carga con el ID esperado y que la auditoría aprobada pasa.
