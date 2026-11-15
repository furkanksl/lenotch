#!/bin/zsh
# Compile the Icon Composer source without flattening its light/dark/tinted layers. actool also produces the legacy
# .icns fallback and the bundle metadata; keep both resources and merge that metadata before signing the app.
#   zsh tools/build_icon.sh /path/to/Contents/Resources /path/to/Contents/Info.plist
set -euo pipefail
if (( $# != 2 )); then
  echo "Usage: $0 <bundle resources directory> <bundle Info.plist>" >&2
  exit 2
fi
RESOURCES=${1:A}
INFO_PLIST=${2:A}
cd "$(dirname "$0")/.."

MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$INFO_PLIST")
TEMP=$(mktemp -d "${TMPDIR:-/tmp/}lenotch-icon.XXXXXX")
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$RESOURCES"
xcrun actool lenotch.icon \
  --compile "$RESOURCES" \
  --platform macosx --target-device mac --minimum-deployment-target "$MIN_OS" \
  --app-icon lenotch --standalone-icon-behavior all \
  --output-partial-info-plist "$TEMP/icon-info.plist" \
  --output-format human-readable-text --warnings --notices
/usr/libexec/PlistBuddy -c "Merge $TEMP/icon-info.plist" "$INFO_PLIST"
