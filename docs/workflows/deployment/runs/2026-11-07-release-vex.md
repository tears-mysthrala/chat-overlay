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
| `scripts/check_release_processes.py` | PASS frente a `scripts/release_process_inventory.json`: 1123 beams, 16 llamadas, 58 archivos de arranque, ERTS y `priv`, 639 ejecutables, librerías y enlaces a BusyBox, ninguna combinación de átomos de lanzamiento en la aplicación ni en Hex, ningún `wget` |
| Misma comprobación sobre la imagen anterior `9d41bbab` | Falla: vuelven `wget` y `ssl_client` |
| Smoke y aislamiento de dos releases | PASS |
| Reescaneo sin VEX, base de Grype 2026-11-07T06:18:48Z | 2 coincidencias, ambas ya conocidas (`busybox`, `busybox-binsh`); ninguna nueva |
| `audit_image.py` con el VEX nuevo | 0 hallazgos activos, 2 cubiertos por el VEX |

`apk del ssl_client` se negó porque apk lo instala por `install_if`: no rompió nada, se excluye con
`!ssl_client`. `zlib` pasa a 1.4-r0 porque 1.3.2-r1 desapareció del índice; el reescaneo no le asocia
ninguna coincidencia.

## La comprobación falla cuando debe

La primera versión solo buscaba `wget` y tres llamadas de Erlang. dev-review y dev-qa mostraron que un
`System.cmd`, un `apply` o un script que lanzara otra cosa pasaban. Ahora compara la imagen con un
inventario: llamadas que lanzan procesos (también `System.cmd`, `System.shell` y `Port.open`),
combinaciones de átomos para `apply` en la aplicación y en Hex, hashes de todo `/app/bin`,
`/app/releases`, `priv` y ERTS, y nombres de ejecutables, librerías y enlaces a BusyBox.

Imágenes derivadas de la resultante, todas fallan con el motivo correcto: beam con `System.cmd`, beam con
`apply(:os, :cmd, ...)`, script que ejecuta `/bin/echo`, enlace a BusyBox en `/opt`, script en `priv`,
`vm.args` modificado y librería nueva; con la versión anterior, además, enlace `wget`, script y beam que
nombran `wget`. Pruebas unitarias para cada control.

Coste intencionado: cualquier cambio de release (módulo nuevo, configuración, OTP o Elixir) cambia
hashes y hace fallar image-security hasta revisar la diferencia y regenerar el inventario con
`python3 scripts/check_release_processes.py --record IMAGEN`.

## Límites

- `/bin/busybox` contiene aún el código de `wget`: un proceso que ya ejecute código en la imagen podría
  invocarlo como applet. La declaración cubre el producto, no un intruso en la imagen.
- La comprobación lee imports, átomos y cadenas de los beams: un `apply` cuyo módulo y función se
  construyan en ejecución sin esos átomos no se ve. Mismo método que el dossier, ampliado.
- CI remota de esta rama sin ejecutar; el cambio de workflow necesita permiso `workflow` para publicarse.
- Rollback: revert; la declaración anterior ya había vencido.
