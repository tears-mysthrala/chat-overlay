#!/bin/sh
set -eu
for seed in 0 424242; do
  CI_EXUNIT_REPORT="/evidence/postgres-$seed.json" mix test --warnings-as-errors --seed "$seed" --max-cases 1 test_postgres/rls_test.exs
done
mix run --no-start scripts/postgres_boot_smoke.exs
