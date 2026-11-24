#!/bin/zsh
# Builds the notarized installer DMG, Sparkle update ZIP, and appcast. Publishes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { print -u2 -r -- "$*"; exit 1; }
(( $# == 0 )) || die "Usage: tools/release.sh"

PLIST=Resources/Info.plist
REPO=https://github.com/furkanksl/lenotch
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$PLIST"; }
[[ "$(plist SUFeedURL)" == "$REPO/releases/latest/download/appcast.xml" ]] || die "Unexpected SUFeedURL in $PLIST."
FEED_KEY=$(plist SUPublicEDKey)
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
MINIMUM=$(plist LSMinimumSystemVersion)
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$BUILD" =~ '^[1-9][0-9]*$' && "$MINIMUM" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] ||
  die "Expected a three-part version, a positive integer build, and a macOS minimum version in $PLIST."

# Read local release settings. Notary credentials stay in Keychain.
[[ ! -f .env.release ]] || source ./.env.release
unset LN_NOTARY_APPLE_ID LN_NOTARY_PASSWORD
TEAM=${LN_NOTARY_TEAM_ID:-}
[[ "$TEAM" =~ '^[A-Z0-9]{10}$' ]] || die "Set LN_NOTARY_TEAM_ID in .env.release (see .env.release.example)."
PROFILE=${LN_NOTARY_KEYCHAIN_PROFILE:-}
[[ -n "$PROFILE" ]] || die "Store notarization credentials in Keychain and set LN_NOTARY_KEYCHAIN_PROFILE in .env.release."

# Select by fingerprint so refreshed certificates with the same name are unambiguous.
IDENTITY=$(security find-identity -v -p codesigning | awk -F '"' -v team="$TEAM" -v requested="${LN_SIGN_IDENTITY:-}" '
  !found && $2 ~ "^Developer ID Application: .* \\(" team "\\)$" {
    split($1, fields, /[[:space:]]*[0-9]+\)[[:space:]]+/)
    hash = fields[2]
    sub(/[[:space:]]+$/, "", hash)
    if (requested == "" || requested == $2 || tolower(requested) == tolower(hash)) {
      print hash
      found = 1
    }
  }')
[[ "$IDENTITY" =~ '^[A-Fa-f0-9]{40}$' ]] || die "No matching Developer ID Application signing identity for team $TEAM in Keychain."

# Only committed code ships: anything uncommitted in what goes into the app stops the release.
INPUTS=(Sources Resources Vendor tools Package.swift Package.resolved build_app.sh lenotch.icon CHANGELOG.md)
COMMIT=$(git rev-parse HEAD)
DIRTY=$(git status --porcelain --untracked-files=normal -- "${INPUTS[@]}")
[[ -z "$DIRTY" ]] || die "Commit the release inputs before building:"$'\n'"$DIRTY"

[[ "$(tools/updates.sh pubkey)" == "$FEED_KEY" ]] || die "The signing key doesn't match SUPublicEDKey in $PLIST."

# Render version notes inline so Sparkle never has to load a GitHub release page into its dialog.
HTML=$(awk -v heading="## $VERSION" '
  $0 == heading { in_version = 1; next }
  /^## / { in_version = 0 }
  in_version && /[^[:space:]]/ {
    sub(/^- /, "")
    gsub(/&/, "\\&amp;")
    gsub(/</, "\\&lt;")
    gsub(/>/, "\\&gt;")
    print "<li>" $0 "</li>"
  }' CHANGELOG.md)
[[ -n "$HTML" ]] || die "Add release notes under '## $VERSION' in CHANGELOG.md."

OUT=dist/release/$VERSION
[[ ! -e "$OUT" ]] || die "$OUT already exists. Move it aside to rebuild this version."
mkdir -p dist/release
STAGING=$(mktemp -d "dist/release/.build-$VERSION.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
APP=$STAGING/LeNotch.app
ARTIFACTS=$STAGING/artifacts
mkdir "$ARTIFACTS"
ZIP=$ARTIFACTS/LeNotch-$VERSION.zip
DMG=$ARTIFACTS/LeNotch-$VERSION.dmg
NOTARY_ZIP=$STAGING/notary.zip
NOTARY_RESULT=$STAGING/notary.json

notarize() {
  local artifact=$1 description=$2 notary_status submission
  print "Submitting $description to Apple's notary service…"
  xcrun notarytool submit "$artifact" --keychain-profile "$PROFILE" --wait --output-format json > "$NOTARY_RESULT" ||
    die "Notarization submission failed for $description. See the notarytool error above."
  notary_status=$(plutil -extract status raw -o - "$NOTARY_RESULT")
  if [[ "$notary_status" != Accepted ]]; then
    submission=$(plutil -extract id raw -o - "$NOTARY_RESULT")
    die "Apple returned '$notary_status' for $description (submission $submission). Retrieve the report with 'xcrun notarytool log $submission' and your notary credentials."
  fi
}

tools/build_adapter.sh
CONFIG=release APP_OUTPUT_DIR="$STAGING" LN_PUBLIC_RELEASE=1 LN_ADHOC= LN_SIGN_IDENTITY="$IDENTITY" ./build_app.sh
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"

notarize "$NOTARY_ZIP" "LeNotch $VERSION app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"

# Sparkle must sign the final archive, including the stapled ticket.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIG=$(tools/updates.sh sign "$ZIP")

# Use the same stapled app for the drag-to-Applications installer.
DMG_ROOT=$STAGING/dmg
mkdir "$DMG_ROOT"
mv "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -srcfolder "$DMG_ROOT" -volname LeNotch -fs HFS+ -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG" "LeNotch $VERSION DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict "$DMG"

DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > "$ARTIFACTS/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LeNotch</title>
    <link>$REPO</link>
    <description>LeNotch updates</description>
    <language>en</language>
    <item>
      <title>LeNotch $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>
$HTML
</ul>]]></description>
      <enclosure url="$REPO/releases/download/v$VERSION/LeNotch-$VERSION.zip" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$ARTIFACTS/appcast.xml"
[[ "$(git rev-parse HEAD)" == "$COMMIT" && -z "$(git status --porcelain --untracked-files=normal -- "${INPUTS[@]}")" ]] ||
  die "Release inputs changed during the build. Build again from the intended commit."
print -r -- "$COMMIT" > "$ARTIFACTS/commit.txt"
[[ ! -e "$OUT" ]] || die "$OUT already exists."
mv "$ARTIFACTS" "$OUT"
print "Built notarized release in $OUT (LeNotch $VERSION, build $BUILD). Nothing was published."
print "Preview publishing with: tools/publish.sh --dry-run"
