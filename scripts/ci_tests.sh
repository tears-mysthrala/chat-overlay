#!/bin/sh
# Full suite twice: serial and concurrent discovery, offline inside CI containers.
set -eu
report_dir=${CI_TEST_REPORT_DIR:-output/tests}
mkdir -p "$report_dir"
# Attempt both runs even when the first fails; keep the failure exit status.
result=0
for seed in 0 424242; do
  cases=1
  if [ "$seed" = 424242 ]; then cases=16; fi
  report="$report_dir/exunit-$seed.json"
  rm -f "$report"
  if CI_EXUNIT_REPORT="$report" mix test --warnings-as-errors --seed "$seed" --max-cases "$cases"; then
    :
  else
    result=1
  fi
done
exit "$result"
