#!/bin/zsh
# Builds the signed, notarized release ZIP and Sparkle appcast. Publishes nothing.
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

# Read a local shell config, if present. Never export these credentials to the build.
[[ ! -f .env.release ]] || source ./.env.release
typeset +x LN_NOTARY_APPLE_ID LN_NOTARY_PASSWORD
TEAM=${LN_NOTARY_TEAM_ID:-}
[[ "$TEAM" =~ '^[A-Z0-9]{10}$' ]] || die "Set LN_NOTARY_TEAM_ID in .env.release (see .env.release.example)."
if [[ -n "${LN_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  NOTARY_AUTH=(--keychain-profile "$LN_NOTARY_KEYCHAIN_PROFILE")
else
  [[ -n "${LN_NOTARY_APPLE_ID:-}" && -n "${LN_NOTARY_PASSWORD:-}" ]] ||
    die "Fill in LN_NOTARY_APPLE_ID and LN_NOTARY_PASSWORD in .env.release, or set LN_NOTARY_KEYCHAIN_PROFILE."
  NOTARY_AUTH=(--apple-id "$LN_NOTARY_APPLE_ID" --team-id "$TEAM" --password "$LN_NOTARY_PASSWORD")
fi

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
NOTARY_ZIP=$STAGING/notary.zip
NOTARY_RESULT=$STAGING/notary.json

tools/build_adapter.sh
CONFIG=release APP_OUTPUT_DIR="$STAGING" LN_PUBLIC_RELEASE=1 LN_ADHOC= LN_SIGN_IDENTITY="$IDENTITY" ./build_app.sh
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"

print "Submitting LeNotch $VERSION to Apple's notary service…"
xcrun notarytool submit "$NOTARY_ZIP" "${NOTARY_AUTH[@]}" --wait --output-format json > "$NOTARY_RESULT" ||
  die "Notarization submission failed. See the notarytool error above."
STATUS=$(plutil -extract status raw -o - "$NOTARY_RESULT")
if [[ "$STATUS" != Accepted ]]; then
  SUBMISSION=$(plutil -extract id raw -o - "$NOTARY_RESULT")
  die "Apple returned '$STATUS' for submission $SUBMISSION. Retrieve the report with 'xcrun notarytool log $SUBMISSION' and your notary credentials."
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"

# Sparkle must sign the final archive, including the stapled ticket.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIG=$(tools/updates.sh sign "$ZIP")
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
