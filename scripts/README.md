# Verificación local

Los scripts de esta carpeta son herramientas de desarrollo. No forman parte de la imagen final.
Ejecutar desde el worktree del issue. No utilizar datos o credenciales reales en pruebas de carga.

## Hook pre-push (obligatorio por clon)

Instalar una vez por clon con `scripts/install-hooks.sh`. Antes de cada push ejecuta:
formato, trazabilidad, secretos, estática y mix check siempre;
build + smoke + auditoría de imagen (SBOM/Grype) además cuando cambia el empaquetado
(`Dockerfile`, `mix.*`, `config/`, `lib/`, `priv/`, `vendor/`, `vex.openvex.json`). Si falla, el push no
sale. Saltarlo (`--no-verify`) debe justificarse en la PR; la CI sigue siendo la
puerta exigible y no se puede saltar.

## CI quality gates (issue #27)

CI runs for pull requests, manual dispatch and weekly audits. It does not deploy.
`source-and-tests` compiles with warnings as errors and audits dependencies, then runs
`sh scripts/ci_tests.sh` inside the validation image with no network, 2 CPUs, 1 GiB
and 128 PIDs. The entire ExUnit suite runs with seed 0 / one case and seed 424242 /
16 cases. Both runs are attempted even if the first fails.

`test/test_helper.exs` writes actual ExUnit counts when `CI_EXUNIT_REPORT` is set.
`python3 scripts/check_test_report.py output/tests/exunit-0.json output/tests/exunit-424242.json`
requires nonempty suites, zero failures/skips/exclusions, matching test counts and both
reports. Missing or malformed evidence fails. Reports are retained for 14 days,
including failed runs. Validator regression tests run with
`python3 -m unittest discover -s scripts/tests`.

`test/token_lifecycle_gate_test.exs` uses message handshakes and synthetic credentials
to exercise cancellation, abrupt coordinator death and binding replacement. It
must pass without skipping or weakening expectations. These gates complement
review; they do not prove coverage of every requirement or real upstream/OBS behavior.

The final `quality-gate` requires successful source and image jobs; failed,
cancelled or skipped prerequisites fail it. Configure `CI / quality-gate` as a
required check through the operator's branch policy before treating it as an
enforced merge restriction. This change does not modify repository permissions
or branch protection. CI changes themselves still need human review.

On the inherited AGY commit `8ef5838`, all three lifecycle regressions fail and
block acceptance of #25/#27. Production fixes are pending; this CI work does not
claim the token lifecycle is complete. Publishing this intentionally red gate for
review requires documenting any pre-push exception; CI and merge gates remain active.

## Carga sostenida sintética (issue #4, REL-08)

`scripts/load.exs` admite entre 10 y 86.400 segundos. Usa diez perfiles demo,
30 fuentes y cien lectores SSE locales, con 200 eventos/s durante diez segundos
y después 50 eventos/s. No contacta plataformas. Para medir la aplicación con
recursos acotados, construir una imagen propia de este worktree y ejecutarla sin red:

```bash
docker build --target validation -t chat-overlay:4-soak-validation .
mkdir -p output/load
# Registrar la revisión y el ID de imagen junto a la evidencia; construir desde un árbol limpio.
git rev-parse HEAD > output/load/source-commit.txt
docker image inspect --format '{{.Id}}' chat-overlay:4-soak-validation > output/load/image-id.txt
# 14.400 = cuatro horas; usar 86.400 para la puerta previa a publicación general.
docker run --rm --network none --cpus 2 --memory 1g --pids-limit 128 \
  -e ERL_FLAGS='+S 2:2' -e LOAD_SOURCE_COMMIT="$(git rev-parse HEAD)" \
  chat-overlay:4-soak-validation mix run --no-start scripts/load.exs 14400 \
  > output/load/soak-4h.json
```

Conservar también el código de salida, la máquina y sus recursos, la versión de
Docker y los límites efectivos. `source_commit` es una etiqueta proporcionada por
el operador; no acredita por sí sola que la imagen corresponda a esa revisión.
La evidencia solo es válida si el proceso termina con código cero y el informe
está completo; una interrupción o un contenedor terminado por OOM no es un PASS.

El JSON conserva los campos previos y añade instantes UTC, duración real incluyendo
drenaje, muestras de memoria total de BEAM y número de procesos cada minuto, y el
máximo **muestreado**. La primera muestra es con lectores conectados y la última
tras su parada. No son RSS del contenedor ni un pico continuo; pueden perderse picos
entre muestras. No se fuerza GC. Como máximo se guardan 1.442 muestras en 24 horas.
El histograma tiene como máximo 1.001 buckets: redondea hacia arriba al milisegundo
(conservador cerca de 100 ms) y agrupa las latencias de al menos 1.000 ms en el
último bucket. Un informe sin muestras no tiene percentil válido.

El proceso falla ante pérdida de muestras, errores de lectores o p95 >=100 ms.
Estos gates no certifican estabilidad de memoria: revisar la serie temporal y
explicar cualquier crecimiento sostenido antes de aceptar REL-08. Tampoco prueban
recuperación de workers, upstream, OBS, navegador ni Internet. Las pruebas de 4 y
24 horas siguen pendientes hasta disponer de sus informes y revisión; un smoke
de 65 segundos solo verifica el muestreo periódico y la entrega corta.
