"""Check local worktree and real GitHub issue without interpolating shell code."""
import json
import os
import pathlib
import re
import subprocess

def run(*args):
    return subprocess.check_output(args, text=True).strip()

event_path = os.environ.get("GITHUB_EVENT_PATH")
if event_path:
    event = json.loads(pathlib.Path(event_path).read_text())
    pr = event.get("pull_request")
    if not pr:
        print("Traceability: not a pull request event")
        raise SystemExit(0)
    branch = pr["head"]["ref"]
    assert not pr["draft"], "Draft PRs are not allowed"
    references = set(re.findall(r"#([1-9][0-9]*)\b", pr["title"] + "\n" + (pr["body"] or "")))
else:
    branch = run("git", "branch", "--show-current")
    current = pathlib.Path(run("git", "rev-parse", "--show-toplevel")).resolve()
    records = run("git", "worktree", "list", "--porcelain").split("\n\n")
    assert any(str(current).replace("\\", "/").lower() in record.lower() and f"refs/heads/{branch}" in record for record in records), "Worktree mismatch"
    references = None

match = re.fullmatch(r"(?:feat|fix|test|docs|chore|security)/([1-9][0-9]*)-[a-z0-9-]+", branch)
assert match, "Branch must be type/ISSUE-slug"
issue = match.group(1)
assert references is None or issue in references, "PR must reference its branch issue"
if not event_path:
    assert re.search(rf"(^|[-_]){issue}([-_]|$)", current.name), "Worktree directory must contain the issue number"
repo = os.environ.get("GITHUB_REPOSITORY") or json.loads(run("gh", "repo", "view", "--json", "nameWithOwner"))["nameWithOwner"]
data = json.loads(run("gh", "api", f"repos/{repo}/issues/{issue}"))
assert data["number"] == int(issue) and "pull_request" not in data, "Referenced issue does not exist"
print(f"Traceability OK: {repo}#{issue}; {branch}")
