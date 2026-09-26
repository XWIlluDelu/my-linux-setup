#!/usr/bin/env python3
"""Offline regressions: temporary data, fake privileged commands, no installers."""
from __future__ import annotations

import http.client
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent


def load_module(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


probe = load_module("nvidia_probe", "drivers/nvidia/probe_nvidia_metadata.py")
manager = load_module("session_manager", "extras/my-ai-tools/claude-session-manager/session_manager_server.py")


def shell_function(relative, name):
    text = (ROOT / relative).read_text()
    match = re.search(rf"(?ms)^{name}\(\) \{{.*?^\}}", text)
    if not match:
        raise AssertionError(f"Missing function: {name}")
    return match.group()


class ShellTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def bash(self, script, **env):
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", f'source "{ROOT}/lib/common.sh"\n' + script],
            text=True, capture_output=True,
            env={**os.environ, "HOME": str(self.work), "TEST_DIR": str(self.work), **env},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_inherited_apply_does_not_authorize_mutation(self):
        self.bash('[[ "$APPLY" == 0 ]]', APPLY="1")

    def test_default_update_dispatch(self):
        # --check is the first optional argument, not both action and argument.
        result = subprocess.run(["bash", str(ROOT / "manage.sh"), "update", "--check"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("check", result.stdout.lower())

    def test_missing_network_probe_tool_is_warning(self):
        self.bash('''
url_reachable() { return 2; }
preflight_reset
preflight_check_network_access test https://example.invalid
[[ "$PREFLIGHT_ERRORS" == 0 ]]
[[ "$PREFLIGHT_WARNINGS" == 1 ]]
''')

    def test_optional_app_stops_on_unhandled_error(self):
        wrapper = shell_function("tasks/apps/install-external-apps.sh", "run_optional_external_step")
        self.bash(wrapper + '''
cleanup() { :; }
LINUX_SETUP_RESULT_LOG="$TEST_DIR/results"
fail_app() { false; touch "$TEST_DIR/continued"; record_result app installed wrong; }
run_optional_external_step app fail_app
[[ ! -e "$TEST_DIR/continued" ]]
[[ "$(result_failed_count)" == 1 ]]
''')

    def test_held_nvidia_packages_are_detected(self):
        function = shell_function("drivers/nvidia/install-nvidia-cuda.sh", "detect_existing_nvidia_state")
        self.bash(function + '''
command_exists() { [[ "$1" == dpkg-query || "$1" == apt-mark ]]; }
dpkg-query() {
  [[ "$*" == *'db:Status-Status'* ]] || return 1
  if [[ "$*" == *'binary:Package'* ]]; then
    printf 'nvidia-open\\tinstalled\\ncuda-keyring\\tinstalled\\nnvidia-old\\tconfig-files\\n'
  else
    printf 'installed\\n'
  fi
}
apt-mark() { printf 'nvidia-open\\n'; }
dpkg_package_installed nvidia-open
NVIDIA_PACKAGE_REGEX='^(nvidia-|cuda-)'
detect_existing_nvidia_state
[[ "${APT_NVIDIA_PACKAGES[*]}" == 'cuda-keyring nvidia-open' ]]
[[ "${HELD_NVIDIA_PACKAGES[*]}" == nvidia-open ]]
''')

    def test_package_refresh_failure_stops_install(self):
        self.bash('''
detect_pkg_manager() { printf apt-get; }
apt_noninteractive() {
  [[ "$1" != update ]] || return 1
  touch "$TEST_DIR/installed"
}
if install_packages example; then exit 1; fi
[[ ! -e "$TEST_DIR/installed" ]]
''')

    def test_microsoft_key_failure_precedes_repository_changes(self):
        function = shell_function("tasks/apps/install-apt-apps.sh", "setup_microsoft_repos")
        self.bash(function + '''
export TMPDIR="$TEST_DIR"
KEY_URL=https://example.invalid/key
curl() { return 1; }
gpg() { return 0; }
as_root() { touch "$TEST_DIR/changed"; }
prune_conflicting_microsoft_sources() { touch "$TEST_DIR/changed"; }
if setup_microsoft_repos; then exit 1; fi
[[ ! -e "$TEST_DIR/changed" ]]
''')

    def test_stage2_requires_booted_layout(self):
        self.bash('''
mountpoint() { return 1; }
findmnt() { printf '/@home'; }
stable_root_subvol_path() { printf '@old'; }
preflight_reset
preflight_check_stage1_layout
[[ "$PREFLIGHT_ERRORS" == 1 ]]
stable_root_subvol_path() { printf '@rootfs'; }
preflight_reset
preflight_check_stage1_layout
[[ "$PREFLIGHT_ERRORS" == 0 ]]
''')

    def test_rollback_entry_preserves_unrelated_grub_entries(self):
        function = shell_function("commands/snapshot/rollback.sh", "install_grub_snapshot_boot_entry")
        self.bash(function + '''
as_root() { [[ "$1" == python3 ]] || exit 99; "$@"; }
run_as_root() { [[ "$1" == mkdir ]] || exit 99; "$@"; }
ROLLBACK_BOOT_DIR="$TEST_DIR/boot"
mkdir -p "$ROLLBACK_BOOT_DIR/grub"
printf '# user menu\\n' > "$ROLLBACK_BOOT_DIR/grub/custom.cfg"
ROLLBACK_CUSTOM_CFG_CONTENT='menuentry old {}'
install_grub_snapshot_boot_entry
ROLLBACK_CUSTOM_CFG_CONTENT='menuentry new {}'
install_grub_snapshot_boot_entry
grep -q '^# user menu$' "$ROLLBACK_BOOT_DIR/grub/custom.cfg"
grep -q '^menuentry new' "$ROLLBACK_BOOT_DIR/grub/custom.cfg"
! grep -q '^menuentry old' "$ROLLBACK_BOOT_DIR/grub/custom.cfg"
''')

    def test_toolkit_only_runfile_keeps_driver_and_desktop(self):
        function = shell_function("drivers/nvidia/install-nvidia-cuda.sh", "run_runfile_preflight")
        self.bash(function + '''
RESOLVED_CUDA_FAMILY=13.4
declare -A CUDA_RUNFILE_INCLUDES_DRIVER=([13.4]=0)
detect_existing_nvidia_state() { APT_NVIDIA_PACKAGES=(nvidia-open cuda-keyring); }
purge_apt_managed_nvidia_stack() { exit 99; }
stop_display_manager_if_needed() { exit 99; }
SYSTEM_SECURE_BOOT=1
GRAPHICAL_SESSION_ACTIVE=1
DISPLAY_MANAGER_ACTIVE=1
run_runfile_preflight
''')

    def test_busy_mount_cleanup_preserves_data(self):
        self.bash('''
mkdir -p "$TEST_DIR/work/mount"
printf valuable > "$TEST_DIR/work/mount/data"
mountpoint() { return 0; }
as_root() { [[ "$1" == umount ]] || exit 99; return 1; }
cleanup_mount_workdir "$TEST_DIR/work" "$TEST_DIR/work/mount"
[[ "$(<"$TEST_DIR/work/mount/data")" == valuable ]]
''')

    def test_github_null_digest_and_literal_metadata(self):
        self.bash('''
github_release_api_get() {
  printf '%s' '{"tag_name":"v1", "published_at":"", "html_url":"", "assets":[{"name":"app_1.deb", "browser_download_url":"https://github.com/test/app/releases/download/v1/app_1.deb", "digest":null}]}'
}
github_release_parse_latest test/app '^app_.*\\.deb$' v
[[ "$GITHUB_ASSET_DIGEST" == '' && "$GITHUB_ASSET_NAME" == app_1.deb ]]
''')

    def test_release_metadata_is_not_executed(self):
        metadata = {"tag_name": f"v$(touch {self.work}/injected)", "assets": [{"name": "app.deb", "browser_download_url": "https://github.com/test/app/releases/download/v1/app.deb"}]}
        self.bash(f'github_release_api_get() {{ printf \'%s\' {shlex.quote(json.dumps(metadata))}; }}\n' + '''
github_release_parse_latest test/app '^app\\.deb$' v
[[ ! -e "$TEST_DIR/injected" ]]
[[ "$GITHUB_RELEASE_TAG" == *'$(touch '* ]]
''')

    def test_wrong_digest_is_rejected(self):
        self.bash('''
curl() {
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then printf corrupt > "$2"; return 0; fi
    shift
  done
  return 1
}
MIRROR_PREFIXES=()
GITHUB_RELEASE_NO_DEFAULT_MIRRORS=1
if github_release_download_asset https://github.com/test/app/releases/download/v1/app "$(printf '%064d' 0)" "$TEST_DIR/asset"; then exit 1; fi
[[ ! -e "$TEST_DIR/asset" ]]
''')

    def test_undigested_download_bypasses_cache_and_mirrors(self):
        self.bash('''
curl() {
  printf '%s\\n' "$*" >> "$TEST_DIR/requests"
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then printf fresh > "$2"; return 0; fi
    shift
  done
  return 1
}
printf stale > "$TEST_DIR/asset"
MIRROR_PREFIXES=(https://untrusted.invalid/)
github_release_download_asset https://github.com/test/app/releases/download/v1/app '' "$TEST_DIR/asset"
[[ "$(<"$TEST_DIR/asset")" == fresh ]]
[[ "$(wc -l < "$TEST_DIR/requests")" == 1 ]]
[[ "$(<"$TEST_DIR/requests")" != *untrusted* ]]
''')

    def test_nvidia_empty_metadata_fields_keep_positions(self):
        metadata = {
            "system": {"id": "debian", "pretty_name": "Debian sid", "arch": "x86_64", "current_repo_supported": False, "preferred_repo_id": "debian13", "preferred_repo_supported": True},
            "gpu": {"name": "Example GPU", "installed_branch": "590", "open_drivers": []},
            "cuda": {"versions": []}, "compatibility": {"by_cuda": {}, "by_driver": {}},
        }
        (self.work / "metadata.json").write_text(json.dumps(metadata))
        function = shell_function("drivers/nvidia/install-nvidia-cuda.sh", "load_metadata")
        self.bash(function + '''
METADATA_JSON="$TEST_DIR/metadata.json"
load_metadata
[[ "$SYSTEM_CURRENT_REPO_SUPPORTED" == 0 && "$SYSTEM_PREFERRED_REPO_ID" == debian13 ]]
[[ "$SYSTEM_VERSION_ID" == '' && "$SYSTEM_CURRENT_REPO_ID" == '' ]]
[[ "$GPU_CURRENT_DRIVER_VERSION" == '' && "$GPU_INSTALLED_BRANCH" == 590 ]]
''')

    def test_skip_driver_requires_no_probe(self):
        result = subprocess.run(["bash", str(ROOT / "manage.sh"), "driver", "nvidia", "--apply", "--method", "skip"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skipped", result.stdout)

    def test_layout_branches_with_fake_mounts(self):
        for mode in ("", "@rootfs"):
            with self.subTest(root_subvolume=mode):
                sandbox = self.work / ("flat" if not mode else "split")
                sandbox.mkdir()
                (sandbox / "etc").mkdir()
                (sandbox / "etc/fstab").write_text("# original\n")
                stub = sandbox / "stub.sh"
                stub.write_text(f'source "{ROOT}/lib/common.sh"\n' + r'''
require_btrfs_root() { :; }
current_root_source() { printf /dev/fake; }
current_root_subvol_path() { printf '%s' "$TEST_ROOT_SUBVOL"; }
current_root_device() { printf /dev/fake; }
current_root_uuid() { printf fake-uuid; }
normalized_btrfs_opts() { printf defaults; }
findmnt() { [[ "$*" != *FSTYPE* ]] || printf btrfs; }
df() { printf 'Filesystem 1K-blocks Used Available Use%% Mounted\nfake 10000 100 9900 1%% /\n'; }
ensure_sudo_session() { :; }
ensure_command() { :; }
install_packages() { :; }
run_as_root() { as_root "$@"; }
disable_grub_btrfs_rootflags_if_possible() { :; }
ensure_grub_saved_default_if_possible() { :; }
rebuild_initramfs_if_possible() { :; }
rebuild_grub_if_possible() { :; }
mountpoint() { [[ -f "${@: -1}/.mounted" ]]; }
as_root() {
  printf '%s\n' "$*" >> "$TEST_DIR/operations"
  case "$1" in
    mount)
      local target="${@: -1}"
      touch "$target/.mounted"
      if [[ "$*" == *subvolid=5* && -n "$TEST_ROOT_SUBVOL" ]]; then mkdir -p "$target/@rootfs"; fi
      if [[ "$*" == *subvol=@rootfs* ]]; then mkdir -p "$target/etc"; fi
      ;;
    umount) rm -f "$2/.mounted"; rmdir "$2/etc" 2>/dev/null || true ;;
    btrfs)
      case "$2 $3" in
        'subvolume show') printf 'Subvolume ID: 256\n' ;;
        'subvolume get-default') printf 'ID 256 gen 1 top level 5 path @rootfs\n' ;;
        'subvolume create'|'subvolume snapshot') mkdir -p "${@: -1}" ;;
        'subvolume set-default') : ;;
        *) exit 98 ;;
      esac ;;
    du) printf '100\tdata\n' ;;
    rsync|cp|mkdir) : ;;
    *) printf 'Unexpected privileged command: %s\n' "$*" >&2; exit 99 ;;
  esac
}
''')
                original = (ROOT / "tasks/system/prepare-btrfs-layout.sh").read_text()
                original = original.replace("/tmp/", f"{sandbox}/")
                original = original.replace("/etc/", f"{sandbox}/etc/")
                original = original.replace('source "$SCRIPT_DIR/../../lib/common.sh"', f'source "{stub}"')
                denied = sandbox / "bin"
                denied.mkdir()
                for command in ("sudo", "mount", "umount", "btrfs", "apt-get", "reboot"):
                    guard = denied / command
                    guard.write_text('#!/bin/sh\nprintf "Unexpected privileged command\\n" >&2\nexit 99\n')
                    guard.chmod(0o755)
                task = sandbox / "task.sh"
                task.write_text(original)
                result = subprocess.run(["bash", str(task), "--apply"], text=True, capture_output=True, env={**os.environ, "TEST_DIR": str(sandbox), "TEST_ROOT_SUBVOL": mode, "TMPDIR": str(sandbox), "PATH": str(denied) + os.pathsep + os.environ["PATH"]})
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                operations = (sandbox / "operations").read_text()
                self.assertIn("subvol=@rootfs", operations)
                if not mode:
                    self.assertRegex(operations, r"--exclude=/@old-before-layout-\S+")
                    self.assertIn("rsync -aAXH --numeric-ids /boot/", operations)


class NvidiaTests(unittest.TestCase):
    def test_removed_driver_packages_are_not_installed(self):
        output = "nvidia-driver-580-open\t580.1\tconfig-files\nnvidia-open\t610.2\tinstalled\n"
        with patch.object(probe, "run_command", return_value=output):
            self.assertEqual(probe.detect_installed_open_branch(), "610")

    def test_fallback_does_not_start_a_login_shell(self):
        def run(args):
            self.assertNotIn("bash", args)
            if args[:2] == ["apt-cache", "search"]:
                return "nvidia-driver-590-open - NVIDIA driver\n"
            return ""
        with patch.object(probe, "run_command", side_effect=run):
            self.assertEqual(probe.fallback_open_drivers()[0]["branch"], "590")

    def test_modern_and_legacy_driver_tables(self):
        notes = '''<table><tr><th>CUDA Toolkit</th><th>Driver</th></tr>
<tr><td><p>CUDA 13.4</p></td><td><p>R615</p></td></tr>
<tr><td><p><span>CUDA 12.9 Update 1</span></p></td><td><p>&gt;= 575.57.08</p></td><td>576.57</td></tr>
<tr><td>CUDA 12.9 GA</td><td>&gt;=575.51.03</td></tr></table>'''
        rows = probe.parse_release_notes(notes)
        self.assertEqual(rows["13.4"]["min_driver"], "615")
        self.assertEqual(rows["12.9"]["release"], "12.9.1")
        self.assertEqual(rows["12.9"]["min_driver"], "575.57.08")
        self.assertEqual(probe.extract_numeric_driver("1:590.44-1"), "590.44")

    def test_modern_patch_version_comes_from_repo(self):
        package = {"package_name": "cuda-toolkit-13-4", "package_version": "13.4.2-1", "package_release": "13.4.2", "runtime_dependency_branch": None, "runtime_dependency_min_version": None}
        notes = {"13.4": {"release": "13.4.0", "label": "CUDA 13.4", "min_driver": "615"}}
        with patch.object(probe, "parse_runfile_info", return_value={"url": "https://example.invalid/toolkit.run", "filename": "toolkit.run", "md5": "0" * 32}) as fetch:
            rows = probe.build_cuda_versions({"13.4": package}, notes, "13.4.2")
        fetch.assert_called_once_with("13.4.2", "13.4.2")
        self.assertFalse(rows[0]["runfile_includes_driver"])


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        values = {"CLAUDE_DIR": self.root, "PROJECTS_DIR": self.root / "projects", "SESSIONS_DIR": self.root / "sessions", "HISTORY_PATH": self.root / "history.jsonl"}
        patches = patch.multiple(manager, **values)
        patches.start()
        self.addCleanup(patches.stop)
        self.project = manager.PROJECTS_DIR / "project"
        self.project.mkdir(parents=True)
        manager.SESSIONS_DIR.mkdir()
        self.transcript = self.project / "session-1.jsonl"
        self.transcript.write_text(json.dumps({"sessionId": "session-1", "type": "user", "content": "hello"}) + "\n")
        manager.HISTORY_PATH.write_text('{"sessionId":"session-1"}\n{"sessionId":"other"}\ninvalid line\n')
        manager.HISTORY_PATH.chmod(0o600)
        self.sidecar = self.project / "session-1" / "tool-results" / "result.txt"
        self.sidecar.parent.mkdir(parents=True)
        self.sidecar.write_text("tool output")

    def test_successful_delete_preserves_other_history_and_permissions(self):
        result = manager.delete_session_record("session-1")
        self.assertEqual(result["deletedHistoryEntries"], 1)
        self.assertFalse(self.transcript.exists())
        self.assertFalse(self.sidecar.exists())
        self.assertEqual(manager.HISTORY_PATH.read_text(), '{"sessionId":"other"}\ninvalid line\n')
        self.assertEqual(manager.HISTORY_PATH.stat().st_mode & 0o777, 0o600)

    def test_reject_traversal_and_symlink_transcripts(self):
        for value in ("../history", "/tmp/file", "..", "x/y", "x\\y"):
            with self.assertRaises(ValueError):
                manager.delete_session_record(value)
        outside = self.root / "outside.jsonl"
        outside.write_text('{"sessionId":"linked"}\n')
        (self.project / "linked.jsonl").symlink_to(outside)
        self.assertIsNone(manager.find_session_transcript_path("linked"))
        with self.assertRaises(FileNotFoundError):
            manager.delete_session_record("linked")
        self.assertTrue(outside.exists())

    def test_history_failure_restores_staged_data(self):
        with patch.object(manager, "compact_history_file", side_effect=OSError("disk error")):
            with self.assertRaises(OSError):
                manager.delete_session_record("session-1")
        self.assertTrue(self.transcript.exists())
        self.assertTrue(self.sidecar.exists())
        self.assertFalse(list(self.root.glob("claude-session-delete-*")))

    def test_failed_rollback_keeps_recovery_files(self):
        with patch.object(manager, "compact_history_file", side_effect=OSError("disk error")), patch.object(manager, "restore_staged_moves", side_effect=OSError("restore error")):
            with self.assertRaisesRegex(RuntimeError, "recover staged files"):
                manager.delete_session_record("session-1")
        staged = list(self.root.glob("claude-session-delete-*"))
        self.assertEqual(len(staged), 1)
        self.assertTrue(list(staged[0].glob("*.jsonl")))

    def test_active_session_is_not_deleted(self):
        (manager.SESSIONS_DIR / "runtime.json").write_text(json.dumps({"sessionId": "session-1", "pid": os.getpid()}))
        with self.assertRaisesRegex(ValueError, "still running"):
            manager.delete_session_record("session-1")
        self.assertTrue(self.transcript.exists())

    def test_http_origin_and_path_validation(self):
        server = manager.HTTPServer(("127.0.0.1", 0), manager.SessionManagerHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port)
        self.addCleanup(connection.close)
        for method, path, headers, expected in (
            ("GET", "/api/sessions", {}, 200),
            ("GET", "/api/sessions", {"Host": "attacker.invalid"}, 403),
            ("DELETE", "/api/sessions/session-1", {"Origin": "https://attacker.invalid"}, 403),
            ("DELETE", "/api/sessions/..%2F..%2Fhistory", {}, 400),
            ("DELETE", "/api/sessions/extra/session-1", {}, 400),
        ):
            connection.request(method, path, headers=headers)
            response = connection.getresponse()
            response.read()
            self.assertEqual(response.status, expected)
        self.assertTrue(self.transcript.exists())


if __name__ == "__main__":
    unittest.main()
