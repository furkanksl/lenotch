#!/bin/zsh
# Exercises publish.sh in a temporary repo with a disposable Sparkle key and no GitHub access.
set -euo pipefail
TOOLS=${0:a:h}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export LOG="$TMP/calls" DRAFT_STATE="$TMP/draft" PREVIOUS_FEED_FILE="$TMP/previous.xml"
mkdir -p "$HOME" "$TMP/bin" "$TMP/repo"
cd "$TMP/repo"
git init -q
mkdir -p Resources tools/updates LeNotch.app/Contents dist/release/1.2.3
cp "$TOOLS"/{publish.sh,updates.sh} tools/
cp "$TOOLS/updates/main.swift" tools/updates/
printf '.build/\n.release/\ndist/\nLeNotch.app/\n' > .gitignore
tools/updates.sh keygen >/dev/null
PUBLIC_KEY=$(tools/updates.sh pubkey)
cat > Resources/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.lenotch</string>
  <key>CFBundleShortVersionString</key><string>1.2.3</string>
  <key>CFBundleVersion</key><string>10</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>SUFeedURL</key><string>https://github.com/furkanksl/lenotch/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
</dict></plist>
EOF
cat > CHANGELOG.md <<'EOF'
# Changelog

## 1.2.3
- Release note & details.
### More detail
- Kept as markdown.

## 1.2.2
- Not part of this release.
EOF
git add .
git -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false commit -qm fixture
export FIXTURE_HEAD=$(git rev-parse HEAD)
OUT=dist/release/1.2.3
export ZIP="$OUT/LeNotch-1.2.3.zip" DMG="$OUT/LeNotch-1.2.3.dmg" APPCAST="$OUT/appcast.xml"
print -r -- "$FIXTURE_HEAD" > "$OUT/commit.txt"
cp Resources/Info.plist LeNotch.app/Contents/
zip -q -r "$ZIP" LeNotch.app
mkdir "$TMP/dmg"
ditto LeNotch.app "$TMP/dmg/LeNotch.app"
ln -s /Applications "$TMP/dmg/Applications"
hdiutil create -srcfolder "$TMP/dmg" -volname LeNotch -fs HFS+ -format UDZO "$DMG" >/dev/null
SIGNATURE=$(tools/updates.sh sign "$ZIP")
WRONG_SIGNATURE=$(tools/updates.sh sign CHANGELOG.md | awk '{ print $1 }')
export ZIP_SIZE=$(/usr/bin/stat -f %z "$ZIP")
DOWNLOAD=https://github.com/furkanksl/lenotch/releases/download/v1.2.3/LeNotch-1.2.3.zip
make_appcast() {
  cat > "$APPCAST" <<EOF
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <link>https://github.com/furkanksl/lenotch</link>
    <item>
      <sparkle:version>10</sparkle:version>
      <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url="$1" $2 />
    </item>
  </channel>
</rss>
EOF
}
make_appcast "$DOWNLOAD" "$SIGNATURE"
rm -rf .release   # A publisher must never need the private key.
export FIXTURE_NOTES=$'- Release note & details.\n### More detail\n- Kept as markdown.'

cat > "$TMP/bin/git" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ "$1" == ls-remote ]] || exec /usr/bin/git "$@"
[[ "$*" == 'ls-remote https://github.com/furkanksl/lenotch.git refs/tags/v1.2.3 refs/tags/v1.2.3^{}' ]]
print tag >> "$LOG"
case "$SCENARIO" in
  wrong_tag) print -r -- $'bad\trefs/tags/v1.2.3';;
  annotated_tag) print -r -- $'object\trefs/tags/v1.2.3\n'"$FIXTURE_HEAD"$'\trefs/tags/v1.2.3^{}';;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/zsh
set -euo pipefail
case "$1:$2" in
  auth:status)
    [[ "$*" == 'auth status --hostname github.com' ]]
    print auth >> "$LOG"
    ;;
  api:--hostname)
    [[ "$3" == github.com ]]
    endpoint=$4
    shift 4
    case "$endpoint" in
      'repos/furkanksl/lenotch/releases?per_page=100')
        print list >> "$LOG"
        [[ "$1:$2" == '--paginate:--jq' ]]
        if [[ "$SCENARIO" == existing || -f "$DRAFT_STATE" ]]; then
          echo '[{"id":42,"tag_name":"v1.2.3","draft":true}]' | jq -r "$3"
        fi
        ;;
      "repos/furkanksl/lenotch/commits/$FIXTURE_HEAD")
        print commit >> "$LOG"
        [[ "$*" == '--jq .sha' ]]
        print -r -- "$FIXTURE_HEAD"
        ;;
      graphql)
        print latest >> "$LOG"
        if [[ -f "$PREVIOUS_FEED_FILE" ]]; then
          echo '{"data":{"repository":{"latestRelease":{"tagName":"v1.2.2","releaseAssets":{"nodes":[{"name":"appcast.xml"}]}}}}}' | jq -r "$argv[-1]"
        else
          echo '{"data":{"repository":{"latestRelease":null}}}' | jq -r "$argv[-1]"
        fi
        ;;
      repos/furkanksl/lenotch/releases/42)
        if [[ "$1" == --method ]]; then
          [[ "$*" == '--method PATCH -F draft=false -f make_latest=true --jq .html_url' ]]
          print publish >> "$LOG"
          print https://github.com/furkanksl/lenotch/releases/tag/v1.2.3
        else
          [[ "$1" == --jq && -f "$DRAFT_STATE" ]]
          print verify >> "$LOG"
          zip_digest="sha256:$(shasum -a 256 < "$ZIP" | awk '{print $1}')"
          dmg_digest="sha256:$(shasum -a 256 < "$DMG" | awk '{print $1}')"
          appcast_digest="sha256:$(shasum -a 256 < "$APPCAST" | awk '{print $1}')"
          dmg_size=$(/usr/bin/stat -f %z "$DMG")
          appcast_size=$(/usr/bin/stat -f %z "$APPCAST")
          [[ "$SCENARIO" != corrupt_upload ]] || appcast_digest=wrong
          [[ "$SCENARIO" != corrupt_dmg ]] || dmg_digest=wrong
          real_target=$FIXTURE_HEAD
          [[ "$SCENARIO" != annotated_tag ]] || real_target=main
          printf '{"draft":true,"tag_name":"v1.2.3","target_commitish":"%s","assets":[{"state":"uploaded","name":"LeNotch-1.2.3.zip","size":%s,"digest":"%s"},{"state":"uploaded","name":"LeNotch-1.2.3.dmg","size":%s,"digest":"%s"},{"state":"uploaded","name":"appcast.xml","size":%s,"digest":"%s"}]}\n' \
            "$real_target" "$ZIP_SIZE" "$zip_digest" "$dmg_size" "$dmg_digest" "$appcast_size" "$appcast_digest" | jq -r "$2"
        fi
        ;;
      *) print -u2 "Unexpected API call: $endpoint"; exit 99 ;;
    esac
    ;;
  release:download)
    [[ "$*" == 'release download --repo github.com/furkanksl/lenotch --pattern appcast.xml --output - -- v1.2.2' ]]
    print download >> "$LOG"
    cat "$PREVIOUS_FEED_FILE"
    ;;
  release:create)
    [[ "$*" == "release create v1.2.3 $ZIP $DMG $APPCAST --repo github.com/furkanksl/lenotch --target $FIXTURE_HEAD --draft --title LeNotch 1.2.3 --notes-file -" ]]
    [[ "$(cat)" == "$FIXTURE_NOTES" ]]
    print create >> "$LOG"
    touch "$DRAFT_STATE"
    [[ "$SCENARIO" != upload_failure ]]
    ;;
  *) print -u2 "Unexpected GitHub command: $*"; exit 99 ;;
esac
EOF
chmod +x "$TMP/bin/"{gh,git}
export PATH="$TMP/bin:$PATH" SCENARIO=normal

fail() { print -u2 -r -- "$*"; exit 1; }
assert_calls() {
  [[ "$(paste -sd ' ' "$LOG")" == "$1" ]] || fail "Unexpected calls: $(cat "$LOG")"
}
expect_failure() {
  local expected=$1 output
  shift
  if output=$(tools/publish.sh "$@" 2>&1); then
    fail "Expected failure: $expected"
  fi
  [[ "$output" == *"$expected"* ]] || fail "Expected '$expected', got: $output"
}
reset() { : > "$LOG"; rm -f "$DRAFT_STATE"; export SCENARIO=$1; }

reset normal
tools/publish.sh --dry-run | grep -q 'Dry run: no GitHub requests made.'
assert_calls ''
mv "$DMG" "$TMP/valid.dmg"
expect_failure "Missing $DMG" --dry-run
print 'Not a disk image' > "$DMG"
expect_failure 'Disk image verification failed' --dry-run
mv "$TMP/valid.dmg" "$DMG"
mv "$OUT/commit.txt" "$TMP/commit.txt"
expect_failure 'Missing dist/release/1.2.3/commit.txt'
print wrong > "$OUT/commit.txt"
expect_failure 'does not match HEAD'
mv "$TMP/commit.txt" "$OUT/commit.txt"
make_appcast "$DOWNLOAD" "$WRONG_SIGNATURE length=\"$ZIP_SIZE\""
expect_failure 'Sparkle signature verification failed'
make_appcast 'https://example.invalid/wrong.zip' "$SIGNATURE"
expect_failure 'Appcast repository or download URL does not match'
assert_calls ''
make_appcast "$DOWNLOAD" "$SIGNATURE"

reset existing
expect_failure 'already exists'
assert_calls 'auth list'

reset wrong_tag
expect_failure 'GitHub tag v1.2.3 does not point to'
assert_calls 'auth list commit tag'

reset normal
cp "$APPCAST" "$PREVIOUS_FEED_FILE"
expect_failure 'Build 10 must be higher'
assert_calls 'auth list commit tag latest download'
rm "$PREVIOUS_FEED_FILE"

reset upload_failure
expect_failure 'Draft creation or upload failed'
assert_calls 'auth list commit tag latest create'
[[ -f "$DRAFT_STATE" ]]

reset corrupt_upload
expect_failure 'uploaded assets do not match'
assert_calls 'auth list commit tag latest create list tag verify'
[[ -f "$DRAFT_STATE" ]]

reset corrupt_dmg
expect_failure 'uploaded assets do not match'
assert_calls 'auth list commit tag latest create list tag verify'
[[ -f "$DRAFT_STATE" ]]

reset normal
tools/publish.sh | grep -q 'https://github.com/furkanksl/lenotch/releases/tag/v1.2.3'
assert_calls 'auth list commit tag latest create list tag verify publish'

reset annotated_tag
sed 's/<sparkle:version>10</<sparkle:version>9</' "$APPCAST" > "$PREVIOUS_FEED_FILE"
tools/publish.sh | grep -q 'https://github.com/furkanksl/lenotch/releases/tag/v1.2.3'
assert_calls 'auth list commit tag latest download create list tag verify publish'
print 'Publish checks passed (all GitHub calls stubbed).'
