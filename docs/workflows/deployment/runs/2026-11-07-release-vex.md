# VEX de release con condiciones — 2026-11-07

Refs #50. Base `c016c06`, dependiente de la rama `fix/46-ci-build-recovery` (PR #84). Aplica el punto 1
de la decisión humana del 2026-11-07 sobre el dossier local `dd5b3a53`. No aprueba el decoder ni publica
artefactos.

## Imagen resultante

`sha256:7424567c934e6404c34842e60d06d755e24fa1652e65fda45733ab17796a7804`, construida en este host
(almacén containerd: el ID es el del índice OCI).

| Comprobación | Resultado |
| --- | --- |
| `/usr/bin/wget`, `/usr/bin/ssl_client`, paquete `ssl_client` | Ausentes |
| `scripts/check_release_processes.py` | PASS: 1123 beams, 16 llamadas inventariadas, ningún `wget` |
| Misma comprobación sobre la imagen anterior `9d41bbab` | Falla: vuelven `wget` y `ssl_client` |
| Smoke y aislamiento de dos releases | PASS |
| Reescaneo sin VEX, base de Grype 2026-11-07T06:18:48Z | 2 coincidencias, ambas ya conocidas (`busybox`, `busybox-binsh`); ninguna nueva |
| `audit_image.py` con el VEX nuevo | 0 hallazgos activos, 2 cubiertos por el VEX |

`apk del ssl_client` se negó porque apk lo instala por `install_if`: no rompió nada, se excluye con
`!ssl_client`. `zlib` pasa a 1.4-r0 porque 1.3.2-r1 desapareció del índice; el reescaneo no le asocia
ninguna coincidencia.

## La comprobación falla cuando debe

Imágenes derivadas de la resultante, en local: enlace `wget` restaurado, script en `/app/bin` que
nombra `wget` y beam que lo contiene. Las tres fallan con el motivo correcto. Ocho pruebas unitarias,
y quitar cualquiera de los cinco controles del script hace fallar al menos una.

## Límites

- `/bin/busybox` contiene aún el código de `wget`: un proceso que ya ejecute código en la imagen podría
  invocarlo como applet. La declaración cubre el producto, no un intruso en la imagen.
- La comprobación lee imports y cadenas de los beams: no ve una llamada construida en tiempo de ejecución
  sin esas pistas. Mismo método que el dossier.
- CI remota de esta rama sin ejecutar; el cambio de workflow necesita permiso `workflow` para publicarse.
- Rollback: revert; la declaración anterior ya había vencido.
