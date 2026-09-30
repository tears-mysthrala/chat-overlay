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
