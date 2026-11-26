"""Exercise the maintainer's local installer without touching Applications or launchd."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class InstallerTests(unittest.TestCase):
    def run_install(self, mode):
        with tempfile.TemporaryDirectory(prefix="tally-install-test-") as temporary:
            root = Path(temporary)
            source = root / "build/Tally.app"
            target = root / "Applications/Tally.app"
            scripts = root / "scripts"
            mocks = root / "mocks"
            for directory in [scripts, mocks, source / "Contents/MacOS", target / "Contents/MacOS"]:
                directory.mkdir(parents=True)
            for bundle, version in [(source, "new"), (target, "old")]:
                (bundle / "version").write_text(version)
                helper = bundle / "Contents/Library/LoginItems/TallyWallpaper.app/Contents/MacOS/tally-wallpaper"
                helper.parent.mkdir(parents=True, exist_ok=True)
                helper.write_text("#!/bin/bash\n" + ("exit 1\n" if mode == "restart_failure" and version == "new" else "echo '{}'\n"))
                helper.chmod(0o755)
            agent = root / "wallpaper.plist"
            agent.write_text("fixture")
            if mode == "login_failure":
                (root / "login.plist").write_text("original login plist")
                (root / "login-loaded").touch()
            text = (Path(__file__).resolve().parents[2] / "scripts/install.sh").read_text()
            replacements = {
                'TARGET="/Applications/Tally.app"': f'TARGET="{target}"',
                'AGENT="$HOME/Library/LaunchAgents/com.aiden.tally.launch.plist"': f'AGENT="{root}/login.plist"',
                'WALL_AGENT="$HOME/Library/Application Support/Tally/Wallpaper/player-agent.plist"': f'WALL_AGENT="{agent}"',
                'LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister': f'LSREGISTER="{mocks}/true"',
            }
            for before, after in replacements.items():
                self.assertEqual(text.count(before), 1)
                text = text.replace(before, after)
            installer = scripts / "install.sh"
            installer.write_text(text)
            commands = {
                "pgrep": "exit 1",
                "xattr": "exit 0",
                "true": "exit 0",
                "sleep": "exit 0",
                "open": 'echo "open $*" >> "$TALLY_TEST_ROOT/events"',
                "codesign": '''if [ "$TALLY_TEST_MODE" = signature_failure ] && [ "${@: -1}" = "$TALLY_TEST_ROOT/Applications/Tally.app" ]; then exit 1; fi''',
                "cp": '''if [ "$TALLY_TEST_MODE" = copy_failure ]; then exit 1; fi
exec /bin/cp "$@"''',
                "launchctl": '''echo "$*" >> "$TALLY_TEST_ROOT/events"
case "$1" in
 print)
   if [ "$TALLY_TEST_MODE" = read_failure ]; then exit 5; fi
   if [[ "$2" = */com.aiden.tally.launch ]]; then
     [ -f "$TALLY_TEST_ROOT/login-loaded" ] || exit 113
     exit 0
   fi
   [ -f "$TALLY_TEST_ROOT/loaded" ] || exit 113
   echo "program = $TALLY_TEST_ROOT/Applications/Tally.app/Contents/Library/LoginItems/TallyWallpaper.app/Contents/MacOS/tally-wallpaper"
   ;;
 bootout)
   if [[ "$2" = */com.aiden.tally.launch ]]; then
     /bin/mv "$TALLY_TEST_ROOT/login-loaded" "$TALLY_TEST_ROOT/login-stopped"
   else
     /bin/mv "$TALLY_TEST_ROOT/loaded" "$TALLY_TEST_ROOT/stopped"
   fi ;;
 bootstrap)
   if [ "$3" = "$TALLY_TEST_ROOT/login.plist" ]; then
     [ "$(cat "$3")" = "original login plist" ] || exit 5
     /usr/bin/touch "$TALLY_TEST_ROOT/login-loaded"
   else
     /usr/bin/touch "$TALLY_TEST_ROOT/loaded"
   fi ;;
esac''',
            }
            for name, body in commands.items():
                executable = mocks / name
                executable.write_text("#!/bin/bash\n" + body + "\n")
                executable.chmod(0o755)
            if mode in {"restart_failure", "running_success"}:
                (root / "loaded").touch()
            environment = dict(os.environ, PATH=f"{mocks}:/usr/bin:/bin", TALLY_TEST_ROOT=str(root), TALLY_TEST_MODE=mode)
            result = subprocess.run(["/bin/bash", str(installer)], env=environment, text=True, capture_output=True, timeout=10)
            if mode == "login_failure":
                self.assertEqual((root / "login.plist").read_text(), "original login plist")
                self.assertTrue((root / "login-loaded").exists())
            version = (target / "version").read_text()
            backups = list((root / "build").glob("tally-install.*/previous/version"))
            events = (root / "events").read_text() if (root / "events").exists() else ""
            return result, version, [p.read_text() for p in backups], events, (root / "loaded").exists()

    def test_success_retains_previous_bundle(self):
        result, version, backups, _, _ = self.run_install("success")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(version, "new")
        self.assertEqual(backups, ["old"])

    def test_copy_failure_restores_old_bundle(self):
        result, version, _, _, _ = self.run_install("copy_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(version, "old")

    def test_signature_failure_restores_old_bundle(self):
        result, version, _, _, _ = self.run_install("signature_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(version, "old")

    def test_player_failure_restores_old_bundle_and_job(self):
        result, version, _, events, loaded = self.run_install("restart_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(version, "old")
        self.assertEqual(events.count("bootstrap"), 2)
        self.assertTrue(loaded)

    def test_running_player_restarts_after_success(self):
        result, version, _, events, loaded = self.run_install("running_success")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(version, "new")
        self.assertEqual(events.count("bootstrap"), 1)
        self.assertTrue(loaded)

    def test_login_failure_restores_old_login_bytes_and_loaded_state(self):
        result, version, _, _, _ = self.run_install("login_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(version, "old")

    def test_unknown_launchctl_error_aborts_before_mutation(self):
        result, version, backups, events, _ = self.run_install("read_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(version, "old")
        self.assertEqual(backups, [])
        self.assertNotIn("bootout", events)


if __name__ == "__main__":
    unittest.main()
