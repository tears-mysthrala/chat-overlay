"""Fail unless a release image can only start the OS processes it already did when #50 was decided.

Human decision 2026-11-07 (#50): the release VEX for BusyBox wget holds only while every built image
keeps wget out of reach. Reads the exact image offline: beams (imports and strings), boot scripts,
and the removed files. Exit 0 only when nothing changed.
"""
import json
import subprocess
import sys

# Modules of the built release that import a process-spawning call, from the dossier of 2026-11-06.
# All are Elixir, IEx or OTP; the application and its Hex dependencies import none.
KNOWN_SPAWNERS = {
    ("Elixir.IEx.Introspection", "os:cmd/1"), ("Elixir.Port", "erlang:open_port/2"),
    ("Elixir.System", "erlang:open_port/2"), ("erlsrv", "erlang:open_port/2"),
    ("escript", "erlang:open_port/2"), ("group", "os:cmd/1"), ("heart", "erlang:open_port/2"),
    ("inet_gethost_native", "erlang:open_port/2"), ("os", "erlang:open_port/2"),
    ("peer", "erlang:open_port/2"), ("pubkey_os_cacerts", "erlang:open_port/2"),
    ("ram_file", "erlang:open_port/2"), ("slave", "erlang:open_port/2"),
    ("user_drv", "erlang:open_port/2"), ("user_drv", "os:cmd/1"), ("win32reg", "erlang:open_port/2"),
}
REMOVED = ["/usr/bin/wget", "/usr/bin/ssl_client"]

SCAN = r'''
Want=[{erlang,open_port,2},{os,cmd,1},{os,cmd,2}],
Beams=filelib:wildcard("/app/lib/*/ebin/*.beam"),
Calls=lists:usort(lists:flatmap(fun(F)->{ok,{M,[{imports,I}]}}=beam_lib:chunks(F,[imports]),
  [[atom_to_list(M),lists:flatten(io_lib:format("~s:~s/~b",[Mo,Fu,Ar]))]||{Mo,Fu,Ar}<-I,lists:member({Mo,Fu,Ar},Want)] end,Beams)),
Wget=[filename:basename(F)||F<-Beams,begin {ok,B0}=file:read_file(F),
  B=case B0 of <<31,139,_/binary>> -> zlib:gunzip(B0); _ -> B0 end, binary:match(B,<<"wget">>)=/=nomatch end],
io:format("~s~n",[json:encode(#{<<"beams">>=>length(Beams),<<"calls">>=>[[list_to_binary(A),list_to_binary(B)]||[A,B]<-Calls],<<"beams_with_wget">>=>[list_to_binary(X)||X<-Wget]})]),
halt().
'''
SHELL = r'''
set -e
E=$(ls -d /app/erts-*)
BOOT=$(ls /app/releases/*/start_clean.boot | head -1)
$E/bin/erl -noshell -boot "${BOOT%.boot}" -boot_var RELEASE_LIB /app/lib -eval "$1" 2>/dev/null | tail -1
echo "--scripts"; grep -l wget /app/bin/* /app/releases/*/*.sh /app/releases/*/*.script "$E"/bin/* 2>/dev/null || true
echo "--present"; for f in REMOVED; do if [ -e "$f" ] || [ -L "$f" ]; then echo "$f"; fi; done
'''.replace("REMOVED", " ".join(REMOVED))


def evaluate(beam_report, scripts, present):
    """Return the list of problems. Empty means the image keeps the decided conditions."""
    problems = []
    if not beam_report.get("beams"):
        problems.append("no beams scanned")
    calls = {tuple(c) for c in beam_report.get("calls", [])}
    for module, call in sorted(calls - KNOWN_SPAWNERS):
        problems.append(f"new process-spawning call: {module} imports {call}")
    for beam in beam_report.get("beams_with_wget", []):
        problems.append(f"beam references wget: {beam}")
    for path in scripts:
        problems.append(f"boot or runtime script references wget: {path}")
    for path in present:
        problems.append(f"removed file is back: {path}")
    return problems


def parse(output):
    lines = output.splitlines()
    beam_report = json.loads(lines[0])
    scripts = lines[lines.index("--scripts") + 1:lines.index("--present")]
    present = lines[lines.index("--present") + 1:]
    return beam_report, [s for s in scripts if s], [p for p in present if p]


def main(image):
    output = subprocess.run(
        ["docker", "run", "--rm", "--network", "none", "--read-only", "--user", "65532:65532",
         "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "128",
         "--memory", "1g", "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m,mode=1777",
         "--entrypoint", "sh", image, "-c", SHELL, "check", SCAN],
        capture_output=True, text=True, timeout=120, check=True).stdout
    beam_report, scripts, present = parse(output)
    problems = evaluate(beam_report, scripts, present)
    print(json.dumps({"image": image, "beams": beam_report["beams"], "calls": len(beam_report["calls"]),
                      "problems": problems}))
    return 1 if problems else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: check_release_processes.py IMAGE")
    raise SystemExit(main(sys.argv[1]))
