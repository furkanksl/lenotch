#!/bin/zsh
# Builds a public release and its update feed, ready to attach to a GitHub release. Publishes nothing.
#   tools/release.sh
# Defaults to furkanksl/lenotch; LN_RELEASE_REPO_URL can override it with a matching SUFeedURL.
# Requires this repository's own SUFeedURL and SUPublicEDKey in Resources/Info.plist.
# Makes dist/release/<version>/LeNotch-<version>.zip (ad-hoc signed, universal) and appcast.xml, whose notes are
# CHANGELOG.md's "## <version>" section. Installed copies read the appcast from the latest release
# (SUFeedURL: releases/latest/download/appcast.xml), so every release must carry both files:
#   gh release create v<version> dist/release/<version>/LeNotch-<version>.zip dist/release/<version>/appcast.xml --repo furkanksl/lenotch
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=Resources/Info.plist
REPO=${LN_RELEASE_REPO_URL:-https://github.com/furkanksl/lenotch}
REPO=${REPO%/}
[[ "$REPO" =~ '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] || {
  print -u2 "LN_RELEASE_REPO_URL must be a GitHub repository URL (default: https://github.com/furkanksl/lenotch)."
  exit 1
}
FEED_URL=$(/usr/libexec/PlistBuddy -c "Print SUFeedURL" $PLIST 2>/dev/null || true)
FEED_KEY=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" $PLIST 2>/dev/null || true)
[[ "$FEED_URL" == "$REPO/releases/latest/download/appcast.xml" && -n "$FEED_KEY" ]] || {
  print -u2 "Configure SUFeedURL as $REPO/releases/latest/download/appcast.xml and your own SUPublicEDKey in $PLIST first."
  exit 1
}
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" $PLIST)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" $PLIST)
MINIMUM=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" $PLIST)

# Only committed code ships: anything uncommitted in what goes into the app stops the release.
DIRTY=$(git status --porcelain -- Sources Resources Vendor tools Package.swift Package.resolved build_app.sh CHANGELOG.md)
[[ -z "$DIRTY" ]] || { print -u2 "Uncommitted changes would ship:\n$DIRTY"; exit 1; }

# The key that signs must be the one the app trusts, or no installed copy will take the update.
[[ "$(tools/updates.sh pubkey)" == "$FEED_KEY" ]] || { print -u2 "The signing key doesn't match SUPublicEDKey in $PLIST"; exit 1; }

# The notes: the changelog's section for this version, as HTML.
NOTES=$(awk -v v="## $VERSION" '$0 == v {on=1; next} /^## / {on=0} on' CHANGELOG.md | sed '/^[[:space:]]*$/d')
[[ -n "$NOTES" ]] || { print -u2 "CHANGELOG.md has no \"## $VERSION\" section"; exit 1; }
HTML=$(print -r -- "$NOTES" | sed -E 's/^- (.*)$/<li>\1<\/li>/; s/\*\*([^*]+)\*\*/<b>\1<\/b>/g')

[[ -d .build/adapter/MediaRemoteAdapter.framework ]] || tools/build_adapter.sh
LN_ADHOC=1 ./build_app.sh

OUT=dist/release/$VERSION
ZIP=$OUT/LeNotch-$VERSION.zip
rm -rf $OUT
mkdir -p $OUT
ditto -c -k --sequesterRsrc --keepParent dist/LeNotch.app $ZIP
SIG=$(tools/updates.sh sign $ZIP)
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > $OUT/appcast.xml <<XML
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
      <sparkle:releaseNotesLink>$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <description><![CDATA[<ul>
$HTML
</ul>]]></description>
      <enclosure url="$REPO/releases/download/v$VERSION/LeNotch-$VERSION.zip" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
XML
xmllint --noout $OUT/appcast.xml
print "Built $ZIP and $OUT/appcast.xml (LeNotch $VERSION, build $BUILD). To publish:"
print "  gh release create v$VERSION $ZIP $OUT/appcast.xml --repo ${REPO#https://github.com/} --title \"LeNotch $VERSION\" --notes-file <(awk -v v=\"## $VERSION\" '\$0 == v {on=1; next} /^## / {on=0} on' CHANGELOG.md)"
