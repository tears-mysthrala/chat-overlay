"""Narrow regressions for project-specific prohibitions; not a full security audit."""
import pathlib
import re

rules = {
    "external atoms": r"\b(?:String\.to_atom|binary_to_atom|list_to_atom)\s*\(",
    "term deserialization": r"binary_to_term\s*\(",
    "runtime evaluation": r"Code\.eval_|\beval\s*\(",
    "chat HTML sinks": r"\.innerHTML\s*=|insertAdjacentHTML\s*\(",
    "shell execution": r"System\.cmd\s*\(|:os\.cmd\s*\(",
}
findings = []
for root in ("lib", "priv/static"):
    for path in pathlib.Path(root).rglob("*"):
        if path.suffix not in (".ex", ".js", ".html"):
            continue
        text = path.read_text(encoding="utf-8")
        for name, pattern in rules.items():
            if re.search(pattern, text):
                findings.append(f"{path}: {name}")
if findings:
    raise SystemExit("\n".join(findings))
print("Project-specific static checks: 0 findings (limited ruleset)")
