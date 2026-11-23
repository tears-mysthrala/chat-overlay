"""Fail unless a release image can only start the OS processes it already did when #50 was decided.

Human decision 2026-11-07 (#50): the release VEX for BusyBox wget holds only while every built image
keeps wget out of reach and launches nothing new. Reads the exact image offline and compares it with
scripts/release_process_inventory.json:
- beams importing a process-launching call, including the Elixir wrappers;
- in the application and Hex dependency beams, atom combinations a dynamic apply would need to
  launch a process (open_port, cmd or shell with os or System, open with Port);
- every file under /app/bin, /app/releases, /app/lib/*/priv and ERTS, by SHA-256 (NIFs and ports too);
- every symlink, copy or hard link of BusyBox, and the names of system executables and shared libraries;
- beams or scripts naming wget, and the removed files.
The file hashes change on purpose with any release change (new module, config, OTP or Elixir), so
such a PR fails here until someone reviews the diff and regenerates the inventory with:
    python3 scripts/check_release_processes.py --record IMAGE
"""
import json
from pathlib import Path
import re
import subprocess
import sys

INVENTORY = Path(__file__).with_name("release_process_inventory.json")
REMOVED = ["/usr/bin/wget", "/usr/bin/ssl_client"]

SCAN = r'''
Want=[{erlang,open_port,2},{os,cmd,1},{os,cmd,2},{'Elixir.System',cmd,2},{'Elixir.System',cmd,3},
  {'Elixir.System',shell,1},{'Elixir.System',shell,2},{'Elixir.Port',open,2}],
Beams=filelib:wildcard("/app/lib/*/ebin/*.beam"),
Calls=lists:usort(lists:flatmap(fun(F)->{ok,{M,[{imports,I}]}}=beam_lib:chunks(F,[imports]),
  [[atom_to_list(M),lists:flatten(io_lib:format("~s:~s/~b",[Mo,Fu,Ar]))]||{Mo,Fu,Ar}<-I,lists:member({Mo,Fu,Ar},Want)] end,Beams)),
Own=string:tokens(os:getenv("OWN_APPS"),","),
Launch=fun(As)->Has=fun(A)->lists:member(A,As) end,
  [A||A<-[open_port,spawn_executable,spawn_driver],Has(A)]++
  [A||A<-[cmd,shell],Has(A),Has(os) orelse Has('Elixir.System')]++
  [open||Has(open),Has('Elixir.Port')] end,
Atoms=lists:sort([[atom_to_list(M),[atom_to_list(A)||A<-L]]||F<-Beams,
  lists:member(hd(string:split(filename:basename(filename:dirname(filename:dirname(F))),"-",trailing)),Own),
  {ok,{M,[{atoms,AL}]}}<-[beam_lib:chunks(F,[atoms])],L<-[Launch([A||{_,A}<-AL])],L=/=[]]),
Wget=[filename:basename(F)||F<-Beams,begin {ok,B0}=file:read_file(F),
  B=case B0 of <<31,139,_/binary>> -> zlib:gunzip(B0); _ -> B0 end, binary:match(B,<<"wget">>)=/=nomatch end],
io:format("~s~n",[json:encode(#{<<"beams">>=>length(Beams),<<"calls">>=>[[list_to_binary(A),list_to_binary(B)]||[A,B]<-Calls],<<"beams_with_wget">>=>[list_to_binary(X)||X<-Wget],<<"atoms">>=>[[list_to_binary(M),[list_to_binary(A)||A<-L]]||[M,L]<-Atoms]})]),
halt().
'''
# /app/releases/COOKIE is random per build and is not a launcher, so it is the one file left out.
# Symlinks under the same roots are recorded by target.
SHELL = r'''
set -e
E=$(ls -d /app/erts-*)
BOOT=$(ls /app/releases/*/start_clean.boot | head -1)
$E/bin/erl -noshell -boot "${BOOT%.boot}" -boot_var RELEASE_LIB /app/lib -eval "$1" 2>/dev/null | tail -1
echo "--files"; { find /app/bin /app/releases /app/lib/*/priv "$E" -type f ! -path /app/releases/COOKIE -exec sha256sum {} +
  find /app/bin /app/releases /app/lib/*/priv "$E" -type l | while read -r l; do echo "link:$(readlink "$l")  $l"; done
  [ -f /app/releases/COOKIE ] || echo "missing  /app/releases/COOKIE"; } 2>/dev/null | sort -k2
echo "--executables"; { for d in /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin; do
  [ -d "$d" ] && for f in "$d"/*; do [ -e "$f" ] || [ -L "$f" ] && echo "$f"; done; done
  find / -xdev -type l 2>/dev/null | while read -r l; do case "$(readlink "$l")" in *busybox*) echo "link $l";; esac; done
  B=$(sha256sum /bin/busybox | cut -d" " -f1)
  find / -xdev -type f -size "$(wc -c < /bin/busybox)c" 2>/dev/null | while read -r f; do
    [ "$(sha256sum "$f" | cut -d" " -f1)" = "$B" ] && echo "busybox-copy $f"; done
  find /lib /usr/lib /usr/local/lib -name '*.so*' 2>/dev/null | sed 's/^/lib /'; } | sort -u
echo "--wget-scripts"; grep -rl wget /app/bin /app/releases /app/lib/*/priv "$E"/bin 2>/dev/null || true
echo "--present"; for f in REMOVED; do if [ -e "$f" ] || [ -L "$f" ]; then echo "$f"; fi; done
'''.replace("REMOVED", " ".join(REMOVED))
SECTIONS = ["--files", "--executables", "--wget-scripts", "--present"]


def parse(output):
    lines = output.splitlines()
    report = json.loads(lines[0])
    marks = [lines.index(s) for s in SECTIONS] + [len(lines)]
    parts = {s: [l for l in lines[marks[i] + 1:marks[i + 1]] if l] for i, s in enumerate(SECTIONS)}
    files = {}
    for line in parts["--files"]:
        digest, path = line.split(None, 1)
        files[path] = digest
    return {"calls": sorted(report["calls"]), "beams": report["beams"],
            "beams_with_wget": report["beams_with_wget"], "atoms": sorted(report["atoms"]), "files": files,
            "executables": parts["--executables"], "wget_scripts": parts["--wget-scripts"],
            "present": parts["--present"]}


def fingerprint(state):
    return {"calls": state["calls"], "atoms": state["atoms"], "files": state["files"],
            "executables": state["executables"]}


def evaluate(state, inventory):
    """Return the list of problems. Empty means the image keeps the decided conditions."""
    problems = []
    if not state["beams"]:
        problems.append("no beams scanned")
    known = {tuple(c) for c in inventory["calls"]}
    for module, call in sorted({tuple(c) for c in state["calls"]} - known):
        problems.append(f"new process-launching call: {module} imports {call}")
    known_atoms = {m: set(a) for m, a in inventory["atoms"]}
    for module, atoms in state["atoms"]:
        extra = sorted(set(atoms) - known_atoms.get(module, set()))
        if extra:
            problems.append(f"new process-related atoms in {module}: {', '.join(extra)}")
    for path in sorted(set(state["files"]) | set(inventory["files"])):
        if state["files"].get(path) != inventory["files"].get(path):
            change = "added" if path not in inventory["files"] else "removed" if path not in state["files"] else "changed"
            problems.append(f"release launcher file {change}: {path}")
    for path in sorted(set(state["executables"]) - set(inventory["executables"])):
        problems.append(f"new system executable, library or BusyBox link: {path}")
    for beam in state["beams_with_wget"]:
        problems.append(f"beam references wget: {beam}")
    for path in state["wget_scripts"]:
        problems.append(f"script references wget: {path}")
    for path in state["present"]:
        problems.append(f"removed file is back: {path}")
    return problems


def own_apps():
    lock = (Path(__file__).resolve().parents[1] / "mix.lock").read_text()
    return ",".join(["chat_overlay"] + sorted(set(re.findall(r'^\s+"([a-z0-9_]+)": \{:hex', lock, re.M))))


def collect(image):
    return parse(subprocess.run(
        ["docker", "run", "--rm", "--network", "none", "--read-only", "--user", "65532:65532",
         "-e", "OWN_APPS=" + own_apps(),
         "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "128",
         "--memory", "1g", "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m,mode=1777",
         "--entrypoint", "sh", image, "-c", SHELL, "check", SCAN],
        capture_output=True, text=True, timeout=180, check=True).stdout)


def main(args):
    if len(args) == 2 and args[0] == "--record":
        INVENTORY.write_text(json.dumps(fingerprint(collect(args[1])), indent=1, sort_keys=True) + "\n")
        return 0
    if len(args) != 1:
        raise SystemExit("usage: check_release_processes.py [--record] IMAGE")
    state = collect(args[0])
    problems = evaluate(state, json.loads(INVENTORY.read_text()))
    print(json.dumps({"image": args[0], "beams": state["beams"], "calls": len(state["calls"]),
                      "files": len(state["files"]), "executables": len(state["executables"]),
                      "problems": problems}))
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
