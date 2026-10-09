#!/bin/sh
set -eu
mkdir /faultout
RECOVERY_TEST_PHASE=prepare mix run --no-start scripts/test_recovery_fault.exs
sha256sum /fixture/source /fixture/baseline > /tmp/before.sha256
set +e
RECOVERY_TEST_PHASE=write LD_PRELOAD=/tmp/recovery_fault.so mix run --no-start scripts/test_recovery_fault.exs
status=$?
set -e
case "$RECOVERY_FAULT_MODE:$status" in
  eio:0|kill:137) ;;
  *) echo "Unexpected fault process exit: $status" >&2; exit 1 ;;
esac
sha256sum -c /tmp/before.sha256
RECOVERY_TEST_PHASE=check mix run --no-start scripts/test_recovery_fault.exs
