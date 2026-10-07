"""Run every upstream regression added by our fixed CPython patches, without skips."""
import sys
import tempfile
import unittest

names = {"test_control_characters", "test_extract_filters_target_none", "test_on_exc_kwargs",
         "test_cleanup_with_symlink_race", "test_parent_mode_preserved"}

def flatten(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from flatten(test)
        else:
            yield test

all_tests = unittest.defaultTestLoader.loadTestsFromNames(
    ["test.test_poplib", "test.test_tarfile", "test.test_shutil", "test.test_tempfile"])
selected = [test for test in flatten(all_tests)
            if any(test._testMethodName == name or test._testMethodName.startswith(name + "_") for name in names)]
missing = [name for name in names if not any(test._testMethodName == name or test._testMethodName.startswith(name + "_") for test in selected)]
if missing:
    raise SystemExit("Missing upstream regression: " + repr(missing))
# Upstream test_cleanup_safe is gated on CPython's PY_SUPPORT_TIER metadata,
# which Alpine/musl does not declare. Execute its exact assertion here as an
# additional mandatory Linux regression; do not count its skipped wrapper as PASS.
def test_cleanup_safe_on_alpine():
    assert sys.platform == "linux"
    assert tempfile._rmtree_use_dir_fd, "FD-relative cleanup must be enabled"

selected.append(unittest.FunctionTestCase(test_cleanup_safe_on_alpine))
result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(selected))
sys.exit(not result.wasSuccessful() or bool(result.skipped))
