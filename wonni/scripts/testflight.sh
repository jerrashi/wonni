#!/usr/bin/env bash
# testflight.sh — Increment build, archive, and upload to TestFlight in one command.
# Run from anywhere in the repo: ./wonni/scripts/testflight.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_DIR/wonni.xcodeproj"
SCHEME="wonni"
ARCHIVE_PATH="$PROJECT_DIR/build/wonni.xcarchive"
EXPORT_PATH="$PROJECT_DIR/build"
EXPORT_OPTS="$PROJECT_DIR/ExportOptions.plist"

# ── Sanity checks ─────────────────────────────────────────────────────────────
if ! command -v xcodebuild &>/dev/null; then
  echo "error: xcodebuild not found — install Xcode command-line tools" >&2; exit 1
fi
if [ ! -f "$EXPORT_OPTS" ]; then
  echo "error: ExportOptions.plist not found at $EXPORT_OPTS" >&2; exit 1
fi

# ── Increment build number ────────────────────────────────────────────────────
echo "Incrementing build number…"
cd "$PROJECT_DIR"
CURRENT=$(agvtool what-version -terse 2>/dev/null | head -1 | tr -d '[:space:]')
NEW_BUILD=$((CURRENT + 1))
echo "  $CURRENT → $NEW_BUILD"
agvtool new-version -all "$NEW_BUILD"

# ── Archive ───────────────────────────────────────────────────────────────────
echo "Archiving scheme '$SCHEME'…"
mkdir -p "$PROJECT_DIR/build"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  -quiet
echo "  Archive → $ARCHIVE_PATH"

# ── Export + upload ───────────────────────────────────────────────────────────
# ExportOptions.plist uses destination:upload so xcodebuild handles the upload.
echo "Exporting and uploading to App Store Connect…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates \
  -quiet
echo "  Done — build $NEW_BUILD submitted to TestFlight."
echo "  Check App Store Connect in ~5 min for processing status."
