#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "--print-info-plist" && $# -eq 1 ]]; then
  exec bash "$ROOT/scripts/app_info_plist.sh"
fi

PACKAGE="$ROOT/app/MacAmbientJev"
APP="$ROOT/.build/MacAmbientJev.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICON_SOURCE="$PACKAGE/Assets/AppIcon.png"

if [[ ! -r "$ICON_SOURCE" ]]; then
  echo "App icon source is missing: $ICON_SOURCE" >&2
  exit 1
fi

CLAUSE_TAGGER_TAG="clause-tagger-54443a6a"
CLAUSE_TAGGER_REPO="Pokojaka/mac-ambient-jev"
CLAUSE_TAGGER_ASSET="clause-tagger-54443a6a.tar.gz"
CLAUSE_TAGGER_SHA256="ed2498c684af47613a267ac1b27bfd7dda23f454b4f5baac85934bf168fa0049"
CLAUSE_TAGGER_CACHE="$ROOT/.build/clause-tagger"
CLAUSE_TAGGER_ARCHIVE="$CLAUSE_TAGGER_CACHE/$CLAUSE_TAGGER_ASSET"

verify_clause_tagger_archive() {
  local actual
  actual="$(shasum -a 256 "$1" | cut -d ' ' -f 1)"
  if [[ "$actual" != "$CLAUSE_TAGGER_SHA256" ]]; then
    echo "Clause tagger archive checksum mismatch: $1" >&2
    echo "expected $CLAUSE_TAGGER_SHA256, got $actual." >&2
    return 1
  fi
}

if [[ -f "$CLAUSE_TAGGER_ARCHIVE" ]]; then
  if ! verify_clause_tagger_archive "$CLAUSE_TAGGER_ARCHIVE"; then
    echo "Delete the cached archive and build again." >&2
    exit 1
  fi
else
  if ! command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI (gh) is required to download the clause tagger model $CLAUSE_TAGGER_ASSET. Install gh and run gh auth login." >&2
    exit 1
  fi
  mkdir -p "$CLAUSE_TAGGER_CACHE"
  # Downloading next to the cache lets the verified archive be renamed into place atomically.
  CLAUSE_TAGGER_DOWNLOAD="$(mktemp -d "$CLAUSE_TAGGER_CACHE/download.XXXXXX")"
  trap 'rm -rf "$CLAUSE_TAGGER_DOWNLOAD"' EXIT
  gh release download "$CLAUSE_TAGGER_TAG" --repo "$CLAUSE_TAGGER_REPO" \
    --pattern "$CLAUSE_TAGGER_ASSET" --dir "$CLAUSE_TAGGER_DOWNLOAD"
  verify_clause_tagger_archive "$CLAUSE_TAGGER_DOWNLOAD/$CLAUSE_TAGGER_ASSET"
  mv "$CLAUSE_TAGGER_DOWNLOAD/$CLAUSE_TAGGER_ASSET" "$CLAUSE_TAGGER_ARCHIVE"
  rmdir "$CLAUSE_TAGGER_DOWNLOAD"
fi

CLAUSE_TAGGER_EXTRACT="$(mktemp -d)"
trap 'rm -rf "$CLAUSE_TAGGER_EXTRACT"' EXIT
tar -xzf "$CLAUSE_TAGGER_ARCHIVE" -C "$CLAUSE_TAGGER_EXTRACT"
for artifact in ClauseTagger.mlpackage tokenizer.json; do
  if [[ ! -e "$CLAUSE_TAGGER_EXTRACT/clause-tagger/$artifact" ]]; then
    echo "Clause tagger archive does not contain clause-tagger/$artifact" >&2
    exit 1
  fi
done

swift build --package-path "$PACKAGE" --build-system swiftbuild --arch arm64 -c release --product MacAmbientJev

BIN_DIR="$(swift build --package-path "$PACKAGE" --build-system swiftbuild --arch arm64 -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN_DIR/MacAmbientJev" "$MACOS/MacAmbientJev"

ICONSET="$RESOURCES/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_SOURCE" \
    --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$ICON_SOURCE" \
    --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICONSET"

MLX_BUNDLE="$BIN_DIR/mlx-swift_Cmlx.bundle"
MLX_METALLIB="$MLX_BUNDLE/Contents/Resources/default.metallib"
if [[ ! -r "$MLX_METALLIB" ]]; then
  echo "SwiftPM MLX shader bundle is missing: $MLX_METALLIB" >&2
  exit 1
fi

shopt -s nullglob
RESOURCE_BUNDLES=("$BIN_DIR"/*.bundle)
if (( ${#RESOURCE_BUNDLES[@]} == 0 )); then
  echo "No SwiftPM resource bundles found in $BIN_DIR" >&2
  exit 1
fi

for bundle in "${RESOURCE_BUNDLES[@]}"; do
  cp -R "$bundle" "$RESOURCES/"
done

cp -R "$CLAUSE_TAGGER_EXTRACT/clause-tagger" "$RESOURCES/clause-tagger"

bash "$ROOT/scripts/app_info_plist.sh" > "$CONTENTS/Info.plist"

SIGNING_IDENTITY="MacAmbientJev Local Signing"
if ! security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1; then
  echo "Code signing certificate \"$SIGNING_IDENTITY\" is not in the keychain. Create it as described in README.md." >&2
  exit 1
fi
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$PACKAGE/Entitlements/MacAmbientJev.entitlements" "$APP"

echo "$APP"
