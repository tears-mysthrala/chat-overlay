"""Fail CI unless each ExUnit run has complete, successful machine-readable evidence."""
import argparse
import json
import pathlib


def validate(path):
    summary = json.loads(pathlib.Path(path).read_text())
    for key in ("total", "failures", "skipped", "excluded"):
        value = summary.get(key)
        if type(value) is not int or value < 0:
            raise ValueError(f"{path}: invalid or missing {key}")
    if summary["total"] == 0 or any(summary[key] for key in ("failures", "skipped", "excluded")):
        raise ValueError(f"{path}: full suite required, got {summary}")
    return summary["total"]


def validate_runs(paths):
    counts = [validate(path) for path in paths]
    if not counts or len(set(counts)) != 1:
        raise ValueError("test discovery differs between runs or evidence is empty")
    return counts[0]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", nargs="+", type=pathlib.Path)
    args = parser.parse_args()
    try:
        total = validate_runs(args.reports)
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        parser.exit(1, f"ExUnit evidence gate failed: {exc}\n")
    print(f"ExUnit evidence: {len(args.reports)} complete runs, {total} tests each, no omissions")
