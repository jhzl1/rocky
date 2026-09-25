#!/usr/bin/env python3
"""Vendors Material Icon Theme's file icons into RockyUI (FIL-09).

Downloads the pinned npm tarball, checks its integrity and version, and writes
Sources/RockyUI/Resources/FileIcons/: one SVG per icon id that the theme's `fileNames`, `fileExtensions` and default
`file` reference, plus github-actions-workflow for the one `languageIds` rule Rocky emulates; `manifest.json`, the
trimmed manifest `FileIconManifest` decodes; and the package's LICENSE. Folder icons, light variants and the other
icons reached only through VS Code language ids are left out. Running it again gives the same files.

Usage: scripts/vendor-file-icons.py
"""

import hashlib
import io
import json
import shutil
import sys
import tarfile
import urllib.request
from base64 import b64encode
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class PinnedPackage:
    name: str
    version: str
    tarball: str
    # npm's `dist.integrity` for that version, so a changed tarball stops the script.
    integrity: str


PACKAGE = PinnedPackage(
    name="material-icon-theme",
    version="5.38.1",
    tarball="https://registry.npmjs.org/material-icon-theme/-/material-icon-theme-5.38.1.tgz",
    integrity="sha512-14cFM4NJGdbuo68rIZTq9TSX0f5BtA6VF+eNX3zq23Z5NoEeVtM4Zn4PpZ0ERl++50jCBrywKFWXmOjbxf0xTA==",
)

# The icon of the `languageIds` rule `FileIcons.iconId` emulates: a .yml or .yaml under .github/workflows/.
LANGUAGE_ID_ICONS = ["github-actions-workflow"]

OUTPUT = Path(__file__).resolve().parent.parent / "Sources" / "RockyUI" / "Resources" / "FileIcons"


def download(package: PinnedPackage) -> bytes:
    with urllib.request.urlopen(package.tarball, timeout=60) as response:
        data: bytes = response.read()
    digest = "sha512-" + b64encode(hashlib.sha512(data).digest()).decode("ascii")
    if digest != package.integrity:
        raise ValueError(f"{package.tarball}: integrity {digest}, expected {package.integrity}")
    return data


def read_member(archive: tarfile.TarFile, name: str) -> bytes:
    try:
        member = archive.extractfile(f"package/{name}")
    except KeyError as err:
        raise ValueError(f"the tarball has no package/{name}") from err
    if member is None:
        raise ValueError(f"package/{name} is not a file")
    with member:
        return member.read()


def check_version(archive: tarfile.TarFile, package: PinnedPackage) -> None:
    manifest = json.loads(read_member(archive, "package.json"))
    if manifest.get("name") != package.name or manifest.get("version") != package.version:
        raise ValueError(
            f"the tarball is {manifest.get('name')} {manifest.get('version')}, expected {package.name} {package.version}"
        )


def unique_ignoring_case(associations: dict[str, str], kind: str) -> dict[str, str]:
    """Rocky matches case-insensitively, so two keys equal but for case would make the lookup ambiguous."""
    seen: dict[str, str] = {}
    for key in associations:
        lower = key.lower()
        if lower in seen:
            raise ValueError(f"{kind}: {seen[lower]!r} and {key!r} differ only in case")
        seen[lower] = key
    return associations


def icon_ids(theme: dict) -> list[str]:
    ids = set(theme["fileNames"].values()) | set(theme["fileExtensions"].values()) | {theme["file"]}
    for icon in LANGUAGE_ID_ICONS:
        if icon not in theme["languageIds"].values():
            raise ValueError(f"no language id uses {icon!r} any more")
        ids.add(icon)
    missing = sorted(icon for icon in ids if icon not in theme["iconDefinitions"])
    if missing:
        raise ValueError(f"icons without a definition: {missing}")
    return sorted(ids)


def svg_member(theme: dict, icon: str) -> str:
    # "./../icons/<file>.svg", relative to dist/; some are "<id>.clone.svg", so the output is named by id.
    path = theme["iconDefinitions"][icon]["iconPath"]
    prefix = "./../icons/"
    if not path.startswith(prefix) or not path.endswith(".svg"):
        raise ValueError(f"{icon}: unexpected icon path {path!r}")
    return "icons/" + path[len(prefix):]


def write(archive: tarfile.TarFile, theme: dict, ids: list[str]) -> int:
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.mkdir(parents=True)
    total = 0
    for icon in ids:
        data = read_member(archive, svg_member(theme, icon))
        (OUTPUT / f"{icon}.svg").write_bytes(data)
        total += len(data)
    trimmed = {
        "file": theme["file"],
        "fileExtensions": unique_ignoring_case(theme["fileExtensions"], "fileExtensions"),
        "fileNames": unique_ignoring_case(theme["fileNames"], "fileNames"),
    }
    text = json.dumps(trimmed, indent=1, sort_keys=True, ensure_ascii=False) + "\n"
    (OUTPUT / "manifest.json").write_text(text, encoding="utf-8")
    (OUTPUT / "LICENSE").write_bytes(read_member(archive, "LICENSE"))
    return total


def main() -> int:
    data = download(PACKAGE)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        check_version(archive, PACKAGE)
        theme = json.loads(read_member(archive, "dist/material-icons.json"))
        ids = icon_ids(theme)
        total = write(archive, theme, ids)
    names = len(theme["fileNames"])
    tails = sum(1 for key in theme["fileNames"] if "/" in key)
    print(
        f"{PACKAGE.name} {PACKAGE.version}: {len(ids)} icons ({total:,} bytes of SVG), "
        f"{names} file names ({tails} path tails), {len(theme['fileExtensions'])} extensions -> {OUTPUT}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
