"""The per-image release check (#50 decision) must fail on each condition it guards."""
import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check_release_processes as check

INVENTORY = {
    "calls": [["Elixir.System", "erlang:open_port/2"], ["os", "erlang:open_port/2"]],
    "atoms": [["Elixir.Plug.Session.ETS", ["cmd"]]],
    "files": {"/app/bin/chat_overlay": "a" * 64, "/app/releases/0.1.0/env.sh": "b" * 64},
    "executables": ["/bin/busybox", "/bin/sh"],
}


def output(calls=None, files=None, executables=None, beams=3, wget_beams=(), wget_scripts=(), present=(), atoms=None):
    report = {"beams": beams, "calls": INVENTORY["calls"] if calls is None else calls,
              "beams_with_wget": list(wget_beams), "atoms": INVENTORY["atoms"] if atoms is None else atoms}
    files = INVENTORY["files"] if files is None else files
    lines = [json.dumps(report), "--files", *[f"{d}  {p}" for p, d in files.items()],
             "--executables", *(INVENTORY["executables"] if executables is None else executables),
             "--wget-scripts", *wget_scripts, "--present", *present]
    return "\n".join(lines) + "\n"


class ReleaseProcessCheck(unittest.TestCase):
    def problems(self, **kwargs):
        return check.evaluate(check.parse(output(**kwargs)), INVENTORY)

    def test_unchanged_image_passes(self):
        self.assertEqual(self.problems(), [])

    def test_fingerprint_round_trips(self):
        self.assertEqual(check.fingerprint(check.parse(output())),
                         {k: (sorted(v) if k == "calls" else v) for k, v in INVENTORY.items()})

    def test_new_launching_call_fails_including_elixir_wrappers(self):
        for call in (["Elixir.ChatOverlay.Web", "Elixir.System:cmd/2"], ["Elixir.ChatOverlay.Web", "Elixir.Port:open/2"],
                     ["Elixir.ChatOverlay.Web", "os:cmd/1"], ["heart", "os:cmd/1"]):
            with self.subTest(call=call):
                self.assertEqual(self.problems(calls=INVENTORY["calls"] + [call]),
                                 [f"new process-launching call: {call[0]} imports {call[1]}"])

    def test_added_changed_or_removed_launcher_file_fails(self):
        cases = {
            "added": dict(INVENTORY["files"], **{"/app/bin/helper": "c" * 64}),
            "changed": dict(INVENTORY["files"], **{"/app/bin/chat_overlay": "d" * 64}),
            "removed": {"/app/bin/chat_overlay": "a" * 64},
        }
        for change, files in cases.items():
            with self.subTest(change=change):
                problems = self.problems(files=files)
                self.assertEqual(len(problems), 1)
                self.assertIn(change, problems[0])

    def test_new_process_atoms_fail(self):
        for atoms in ([["Elixir.Plug.Session.ETS", ["cmd", "open_port"]]],
                      INVENTORY["atoms"] + [["Elixir.ChatOverlay.Web", ["cmd"]]]):
            with self.subTest(atoms=atoms):
                problems = self.problems(atoms=atoms)
                self.assertEqual(len(problems), 1)
                self.assertIn("new process-related atoms", problems[0])

    def test_symlink_target_counts_as_launcher_file(self):
        files = dict(INVENTORY["files"], **{"/app/bin/helper": "link:/bin/echo"})
        self.assertEqual(self.problems(files=files), ["release launcher file added: /app/bin/helper"])

    def test_new_system_executable_fails(self):
        self.assertEqual(self.problems(executables=INVENTORY["executables"] + ["/usr/local/bin/x"]),
                         ["new system executable, library or BusyBox link: /usr/local/bin/x"])

    def test_wget_and_removed_files_fail(self):
        self.assertEqual(len(self.problems(wget_beams=["X.beam"])), 1)
        self.assertEqual(len(self.problems(wget_scripts=["/app/bin/chat_overlay"])), 1)
        for path in check.REMOVED:
            with self.subTest(path=path):
                self.assertEqual(self.problems(present=[path]), [f"removed file is back: {path}"])

    def test_empty_scan_fails(self):
        self.assertIn("no beams scanned", self.problems(beams=0))

    def test_malformed_scan_output_raises(self):
        with self.assertRaises((ValueError, json.JSONDecodeError)):
            check.parse("not json\n--files\n")

    def test_committed_inventory_is_well_formed(self):
        inventory = json.loads(check.INVENTORY.read_text())
        self.assertEqual(set(inventory), {"calls", "atoms", "files", "executables"})
        self.assertTrue(inventory["calls"] and inventory["files"] and inventory["executables"])
        self.assertTrue(all(len(d) == 64 for d in inventory["files"].values()))
        self.assertNotIn("/usr/bin/wget", inventory["executables"])
        self.assertNotIn("/usr/bin/ssl_client", inventory["executables"])
        self.assertFalse([e for e in inventory["executables"] if e.startswith("link ") and "wget" in e])


if __name__ == "__main__":
    unittest.main()
