#!/usr/bin/env python3
"""Export the Godot Web client to web-build/ for local use or Render Static Sites."""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import stat
import subprocess
import sys
import urllib.request
import urllib.error
import zipfile
from pathlib import Path


GODOT_VERSION = "4.7.2"
PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = PROJECT_ROOT / "config" / "server_url.cfg"
GODOT_CACHE = Path.home() / ".cache" / "slave-card" / f"godot-{GODOT_VERSION}"
TEMPLATE_VERSION = f"{GODOT_VERSION}.stable"


def download(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {destination.name}...")
    urllib.request.urlretrieve(url, destination)


def template_directory() -> Path:
    system = platform.system()
    if system == "Windows":
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming")) / "Godot"
    elif system == "Darwin":
        base = Path.home() / "Library" / "Application Support" / "Godot"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "godot"
    return base / "export_templates" / TEMPLATE_VERSION


def install_export_templates() -> None:
    target = template_directory()
    if (target / "web_nothreads_release.zip").is_file():
        return
    archive = GODOT_CACHE / f"Godot_v{GODOT_VERSION}-stable_export_templates.tpz"
    if not archive.is_file():
        download(
            f"https://godot-releases.nbg1.your-objectstorage.com/{GODOT_VERSION}-stable/"
            f"Godot_v{GODOT_VERSION}-stable_export_templates.tpz",
            archive,
        )
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as package:
        for item in package.infolist():
            if item.is_dir():
                continue
            member = Path(item.filename)
            if member.parts and member.parts[0] == "templates":
                relative = Path(*member.parts[1:])
                if relative.parts:
                    output = target / relative
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_bytes(package.read(item))


def godot_executable() -> str:
    configured = os.environ.get("GODOT_BIN", "").strip()
    if configured:
        return configured
    installed = shutil.which("godot") or shutil.which("godot4")
    if installed:
        return installed
    if platform.system() != "Linux":
        raise RuntimeError("Install Godot 4.7.2 or set GODOT_BIN to its executable.")

    executable = GODOT_CACHE / "godot"
    if not executable.is_file():
        archive = GODOT_CACHE / f"Godot_v{GODOT_VERSION}-stable_linux.x86_64.zip"
        download(
            f"https://godot-releases.nbg1.your-objectstorage.com/{GODOT_VERSION}-stable/"
            f"Godot_v{GODOT_VERSION}-stable_linux.x86_64.zip",
            archive,
        )
        with zipfile.ZipFile(archive) as package:
            binary_name = f"Godot_v{GODOT_VERSION}-stable_linux.x86_64"
            executable.write_bytes(package.read(binary_name))
        executable.chmod(executable.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return str(executable)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--require-production-url",
        action="store_true",
        help="Require SLAVE_CARD_SERVER_URL to be a public ws:// or wss:// URL.",
    )
    args = parser.parse_args()

    production_url = os.environ.get("SLAVE_CARD_SERVER_URL", "").strip()
    if args.require_production_url and not production_url:
        parser.error("Set SLAVE_CARD_SERVER_URL to the public WebSocket URL before exporting.")
    if production_url and not production_url.startswith(("ws://", "wss://")):
        parser.error("SLAVE_CARD_SERVER_URL must start with ws:// or wss://.")

    executable = godot_executable()
    install_export_templates()
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    original = CONFIG_PATH.read_bytes() if CONFIG_PATH.exists() else None
    try:
        if production_url:
            CONFIG_PATH.write_text(f'[network]\nserver_url="{production_url}"\n', encoding="utf-8")
        output = PROJECT_ROOT / "web-build" / "index.html"
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [executable, "--headless", "--path", str(PROJECT_ROOT), "--export-release", "Web", str(output)],
            check=True,
            cwd=PROJECT_ROOT,
        )
    finally:
        if original is None:
            CONFIG_PATH.unlink(missing_ok=True)
        else:
            CONFIG_PATH.write_bytes(original)
    print(f"Web client exported to {output.parent}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, urllib.error.URLError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"Web export failed: {error}", file=sys.stderr)
        raise SystemExit(1)
