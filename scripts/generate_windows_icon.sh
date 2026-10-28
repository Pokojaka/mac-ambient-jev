#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SOURCE="$ROOT/app/MacAmbientJev/Assets/AppIcon.png"
[[ -f "$SOURCE" && -r "$SOURCE" ]] || { echo "App icon source is missing or unreadable: $SOURCE" >&2; exit 1; }
DIMENSIONS="$(sips -g pixelWidth -g pixelHeight "$SOURCE" | awk '/pixelWidth:/ { width=$2; width_seen=1 } /pixelHeight:/ { height=$2; height_seen=1 } END { if (!width_seen || !height_seen) exit 1; print width, height }')" || { echo "Could not read app icon dimensions: $SOURCE" >&2; exit 1; }
if [[ "$DIMENSIONS" != "1024 1024" ]]; then echo "App icon must be 1024x1024 pixels; found: $DIMENSIONS" >&2; exit 1; fi
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
for size in 16 24 32 48 64 128 256; do sips -z "$size" "$size" "$SOURCE" --out "$TEMP_DIR/$size.png" >/dev/null; done
python3 - "$ROOT/app/Windows/src/MacAmbientJev.WinUI/Assets/AppIcon.ico" "$TEMP_DIR" <<'PY'
from pathlib import Path
import struct, sys

destination, temporary = Path(sys.argv[1]), Path(sys.argv[2])
sizes = (16, 24, 32, 48, 64, 128, 256)
pngs = [(size, (temporary / f"{size}.png").read_bytes()) for size in sizes]
entries, offset = [], 6 + 7 * 16
for size, png in pngs:
    entries.append(struct.pack("<BBBBHHII", size if size < 256 else 0, size if size < 256 else 0, 0, 0, 1, 32, len(png), offset))
    offset += len(png)
data = struct.pack("<HHH", 0, 1, 7) + b"".join(entries) + b"".join(png for _, png in pngs)
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_bytes(data)
PY
