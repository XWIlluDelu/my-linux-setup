#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = sorted(
    path
    for path in ROOT.rglob("*.md")
    if ".git" not in path.parts and ".pi-subagents" not in path.parts
)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def check_links() -> None:
    link_pattern = re.compile(r"\[[^\]]*\]\(([^)]*)\)")
    for document in DOCS:
        text = document.read_text(encoding="utf-8")
        for raw_target in link_pattern.findall(text):
            target = raw_target.strip()
            if not target:
                fail(f"empty Markdown link in {document.relative_to(ROOT)}")
            target = target.split("#", 1)[0]
            if not target or re.match(r"^[a-z]+://", target) or target.startswith("mailto:"):
                continue
            resolved = (document.parent / target).resolve()
            if not resolved.exists():
                fail(
                    f"missing Markdown link in {document.relative_to(ROOT)}: {raw_target}"
                )


def check_stale_paths() -> None:
    stale_patterns = (
        r"flows/",
        r"commands/maintenance/",
        r"commands/snapshots/",
        r"commands/update/update-(?:all|apps|packages)\.sh",
        r"lib/btrfs-layout\.sh",
        r"tasks/apps/external/(?:desktop-apps|package-installers|user-assets)\.sh",
    )
    combined = re.compile("|".join(stale_patterns))
    for document in DOCS:
        match = combined.search(document.read_text(encoding="utf-8"))
        if match:
            fail(
                f"stale internal path in {document.relative_to(ROOT)}: {match.group(0)}"
            )


def check_repository_map() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    for directory in ("commands", "tasks", "lib", "assets", "drivers", "extras", "tests"):
        if f"`{directory}/`" not in readme:
            fail(f"README repository map omits {directory}/")

    for directory in sorted(
        path.name for path in (ROOT / "extras").iterdir() if path.is_dir()
    ):
        if f"`extras/{directory}/`" not in readme:
            fail(f"README extras table omits extras/{directory}/")


def check_shell_boundary() -> None:
    boundary_docs = {
        "README.md": (ROOT / "README.md").read_text(encoding="utf-8"),
        "LOCAL_ENV_AGENT_NOTES.md": (ROOT / "LOCAL_ENV_AGENT_NOTES.md").read_text(
            encoding="utf-8"
        ),
    }
    managed_paths = (
        "~/.profile",
        "~/.bashrc",
        "~/.zshrc",
        "~/.config/shell/env.sh",
        "~/.config/shell/aliases.sh",
        "~/.config/starship.toml",
        "~/.local/state/linux-setup/shell-env-profile",
        "~/.local/state/linux-setup/shell-env.env",
    )
    for document, text in boundary_docs.items():
        for managed_path in managed_paths:
            if f"`{managed_path}`" not in text:
                fail(f"{document} omits managed file {managed_path}")
        if "# Linux Setup tmux config" not in text:
            fail(f"{document} omits conditional legacy tmux cleanup")


def check_bundled_tool_docs() -> None:
    pinky_dir = ROOT / "extras/pinky"
    pinky_readme = (pinky_dir / "README.md").read_text(encoding="utf-8")
    metadata = json.loads((pinky_dir / "metadata.json").read_text(encoding="utf-8"))
    if f"Pinky v{metadata['version']}" not in pinky_readme:
        fail("Pinky README version does not match metadata.json")
    for key in ("pin-key", "above-key", "unpin-all-key"):
        if f"`{key}`" not in pinky_readme:
            fail(f"Pinky README omits configurable schema key {key}")

    session_readme = (
        ROOT / "extras/my-ai-tools/claude-session-manager/README.md"
    ).read_text(encoding="utf-8")
    if "Python 3.10+" not in session_readme:
        fail("Claude Session Manager README must match its Python 3.10 syntax")
    for requirement in ("lsof", "ps", "seq"):
        if f"`{requirement}`" not in session_readme:
            fail(f"Claude Session Manager README omits runtime tool {requirement}")
    if "${TMPDIR:-/tmp}/session-manager.log" not in session_readme:
        fail("Claude Session Manager README omits its TMPDIR-aware log path")


def main() -> None:
    check_links()
    check_stale_paths()
    check_repository_map()
    check_shell_boundary()
    check_bundled_tool_docs()
    print("documentation checks: pass")


if __name__ == "__main__":
    main()
