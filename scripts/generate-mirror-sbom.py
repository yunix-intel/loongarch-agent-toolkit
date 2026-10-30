#!/usr/bin/env python3
"""Generate the public agent-binaries component summary from real assets.

This is deliberately not a dependency graph: syft runs in the private build
workflows, where the patched/overridden source tree exists.  This file only
records the exact bytes that were mirrored, so its checksums cannot drift.
"""

import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

PATTERNS = (
    (re.compile(r"^codex-rust-v([0-9.]+)-loongarch64[.]tar[.]gz$"), "Codex", "Apache-2.0"),
    (re.compile(r"^zcode-cli_([0-9.]+)_loong64[.]tar[.]gz$"), "ZCode-CLI", "Apache-2.0"),
    (re.compile(r"^zcode-desktop_([0-9.]+)_loong64[.]deb$"), "ZCode-Desktop", "Apache-2.0"),
    (re.compile(r"^zcode-desktop-standalone_([0-9.]+)_loong64[.]deb$"), "ZCode-Standalone", "Apache-2.0"),
    (re.compile(r"^cc-switch_([0-9.]+)[.]loong64[.]1_loong64[.]deb$"), "cc-switch", "MIT"),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: generate-mirror-sbom.py OUTPUT BASE_URL DIR [DIR...]", file=sys.stderr)
        return 2
    output = Path(sys.argv[1])
    base_url = sys.argv[2].rstrip("/")
    packages = []
    for directory in sys.argv[3:]:
        for path in sorted(Path(directory).iterdir()):
            if not path.is_file():
                continue
            for pattern, label, license_id in PATTERNS:
                match = pattern.match(path.name)
                if not match:
                    continue
                packages.append(
                    {
                        "name": path.name,
                        "SPDXID": f"SPDXRef-Package-{label}",
                        "versionInfo": match.group(1),
                        "licenseConcluded": license_id,
                        "downloadLocation": f"{base_url}/{path.name}",
                        "checksums": [{"algorithm": "SHA256", "checksumValue": sha256(path)}],
                    }
                )
                break
    if not packages:
        print("no mirrored binary assets found", file=sys.stderr)
        return 1
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"agent-binaries-{now[:10]}",
        "documentNamespace": base_url.rsplit("/releases/", 1)[0] + "/releases/tag/agent-binaries",
        "creationInfo": {
            "created": now,
            "creators": ["Tool: loongarch-agent-toolkit mirror"],
        },
        "packages": packages,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {output} ({len(packages)} packages)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
