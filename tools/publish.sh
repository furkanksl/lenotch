#!/bin/zsh
# Publishes a prepared LeNotch release. Use --dry-run to validate it entirely offline.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { print -u2 -r -- "$*"; exit 1; }
DRY_RUN=0
case "$#:${1:-}" in
  0:) ;;
  1:--dry-run) DRY_RUN=1 ;;
  1:--help|1:-h) print "Usage: tools/publish.sh [--dry-run]"; exit 0 ;;
  *) die "Usage: tools/publish.sh [--dry-run]" ;;
esac

PLIST=Resources/Info.plist
REPO=furkanksl/lenotch
REPO_URL="https://github.com/$REPO"
FEED_URL="$REPO_URL/releases/latest/download/appcast.xml"
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$PLIST"; }
[[ "$(plist SUFeedURL)" == "$FEED_URL" ]] || die "Expected SUFeedURL to be $FEED_URL in $PLIST."
FEED_KEY=$(plist SUPublicEDKey) || die "Missing SUPublicEDKey in $PLIST."
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
MINIMUM=$(plist LSMinimumSystemVersion)
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$BUILD" =~ '^[1-9][0-9]*$' ]] ||
  die "Expected a three-part version and a positive integer build in $PLIST."
TAG="v$VERSION"
TITLE="LeNotch $VERSION"
OUT="dist/release/$VERSION"
ZIP_NAME="LeNotch-$VERSION.zip"
ZIP="$OUT/$ZIP_NAME"
APPCAST="$OUT/appcast.xml"
SOURCE="$OUT/commit.txt"
for artifact in "$ZIP" "$APPCAST" "$SOURCE"; do
  [[ -f "$artifact" && -s "$artifact" ]] || die "Missing $artifact. Run tools/release.sh first."
done

COMMIT=$(git rev-parse HEAD)
[[ "$(<"$SOURCE")" == "$COMMIT" ]] || die "$SOURCE does not match HEAD. Check out the build's commit or rebuild."
DIRTY=$(git status --porcelain --untracked-files=normal -- Sources Resources Vendor tools Package.swift Package.resolved build_app.sh lenotch.icon CHANGELOG.md)
[[ -z "$DIRTY" ]] || die "Release inputs have uncommitted changes:"$'\n'"$DIRTY"
if git show-ref --verify --quiet "refs/tags/$TAG"; then
  [[ "$(git rev-parse "refs/tags/$TAG^{commit}")" == "$COMMIT" ]] || die "Local tag $TAG does not point to $COMMIT."
fi

NOTES=$(awk -v heading="## $VERSION" '
  { sub(/\r$/, "") }
  $0 == heading { sections++; in_version = 1; next }
  /^## / { in_version = 0 }
  in_version { print; if (/[^[:space:]]/) has_notes = 1 }
  END { if (sections != 1 || !has_notes) exit 1 }
' CHANGELOG.md) || die "Add one nonempty '## $VERSION' section to CHANGELOG.md."

# Verify GitHub received the same files that were checked locally.
file_digest() { /usr/bin/shasum -a 256 < "$1" | awk '{ print "sha256:" $1 }'; }
if (( ! DRY_RUN )); then
  ZIP_DIGEST=$(file_digest "$ZIP")
  APPCAST_DIGEST=$(file_digest "$APPCAST")
fi

ITEM=/rss/channel/item
ENCLOSURE="$ITEM/enclosure"
SPARKLE_NS=http://www.andymatuschak.org/xml-namespaces/sparkle
sparkle_field() { print -r -- "*[local-name()='$1' and namespace-uri()='$SPARKLE_NS']"; }
xpath() { /usr/bin/xmllint --nonet --xpath "$1" "$APPCAST"; }
[[ "$(xpath "count($ITEM)=1 and count($ENCLOSURE)=1")" == true ]] || die "Expected one item and one enclosure in $APPCAST."
[[ "$(xpath 'string(/rss/channel/link)')" == "$REPO_URL" &&
   "$(xpath "string($ENCLOSURE/@url)")" == "$REPO_URL/releases/download/$TAG/$ZIP_NAME" ]] ||
  die "Appcast repository or download URL does not match $REPO_URL and $TAG."
[[ "$(xpath "string($ITEM/$(sparkle_field version))")" == "$BUILD" &&
   "$(xpath "string($ITEM/$(sparkle_field shortVersionString))")" == "$VERSION" &&
   "$(xpath "string($ITEM/$(sparkle_field minimumSystemVersion))")" == "$MINIMUM" ]] ||
  die "Appcast version, build or macOS minimum does not match $PLIST."
ZIP_SIZE=$(/usr/bin/stat -f %z "$ZIP")
APPCAST_SIZE=$(/usr/bin/stat -f %z "$APPCAST")
[[ "$(xpath "string($ENCLOSURE/@length)")" == "$ZIP_SIZE" ]] || die "Appcast byte length does not match $ZIP."
SIGNATURE=$(xpath "string($ENCLOSURE/@$(sparkle_field edSignature))")
[[ -n "$SIGNATURE" ]] || die "Missing Sparkle signature in $APPCAST."
tools/updates.sh verify "$ZIP" "$FEED_KEY" "$SIGNATURE" || die "Sparkle signature verification failed."

APP_PLIST=$(/usr/bin/unzip -p "$ZIP" LeNotch.app/Contents/Info.plist | /usr/bin/plutil -convert xml1 -o - -) ||
  die "Could not read the archived LeNotch.app's Info.plist."
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion SUFeedURL SUPublicEDKey; do
  [[ "$(/usr/bin/plutil -extract "$key" raw -o - - <<< "$APP_PLIST")" == "$(plist "$key")" ]] ||
    die "Archived LeNotch.app has a different $key than $PLIST."
done

print "Ready: $TITLE (build $BUILD), $TAG at $COMMIT, on $REPO."
print "Assets: $ZIP and $APPCAST"
if (( DRY_RUN )); then
  print "Release notes:"
  print -r -- "$NOTES"
  print "Dry run: no GitHub requests made."
  exit 0
fi

command -v gh >/dev/null || die "Install GitHub CLI and authenticate with 'gh auth login --hostname github.com'."
export GH_PROMPT_DISABLED=1
gh_api() { gh api --hostname github.com "$@"; }
GITHUB_REPO="github.com/$REPO"
API_REPO="repos/$REPO"
release_ids() {
  gh_api "$API_REPO/releases?per_page=100" --paginate --jq ".[] | select(.tag_name == \"$TAG\") | .id"
}
check_remote_tag() {
  local refs
  refs=$(git ls-remote "$REPO_URL.git" "refs/tags/$TAG" "refs/tags/$TAG^{}") || die "Could not verify the GitHub tag."
  # Prefer the peeled commit for annotated tags.
  REMOTE_TAG_COMMIT=$(print -r -- "$refs" | awk '$2 ~ /\^\{\}$/ { peeled = $1; next } NF { tag = $1 } END { print peeled ? peeled : tag }')
  [[ -z "$REMOTE_TAG_COMMIT" || "$REMOTE_TAG_COMMIT" == "$COMMIT" ]] || die "GitHub tag $TAG does not point to $COMMIT."
}

gh auth status --hostname github.com >/dev/null 2>&1 || die "Authenticate with 'gh auth login --hostname github.com'."
EXISTING=$(release_ids) || die "Could not check existing releases; nothing was uploaded."
[[ -z "$EXISTING" ]] || die "A release or draft already exists for $TAG on $REPO. Nothing was uploaded."
REMOTE_COMMIT=$(gh_api "$API_REPO/commits/$COMMIT" --jq .sha) || die "Push $COMMIT to $REPO before publishing."
[[ "$REMOTE_COMMIT" == "$COMMIT" ]] || die "Could not verify $COMMIT on $REPO."
check_remote_tag

# An older manual release may not have an appcast. Once it does, Sparkle builds must increase.
LATEST=$(gh_api graphql -f owner="${REPO%/*}" -f repo="${REPO#*/}" -f query='
  query($owner: String!, $repo: String!) {
    repository(owner: $owner, name: $repo) {
      latestRelease { tagName releaseAssets(first: 100) { nodes { name } } }
    }
  }
' --jq '.data.repository.latestRelease | select(. != null) | [.tagName, any(.releaseAssets.nodes[]; .name == "appcast.xml")] | @tsv') ||
  die "Could not check the latest release; nothing was uploaded."
if [[ "$LATEST" == *$'\ttrue' ]]; then
  PREVIOUS_TAG=${LATEST%$'\ttrue'}
  PREVIOUS_FEED=$(gh release download --repo "$GITHUB_REPO" --pattern appcast.xml --output - -- "$PREVIOUS_TAG") ||
    die "Could not read the latest appcast ($PREVIOUS_TAG)."
  PREVIOUS_BUILD=$(/usr/bin/xmllint --nonet --xpath "string(($ITEM/$(sparkle_field version) | $ENCLOSURE/@$(sparkle_field version))[1])" - <<< "$PREVIOUS_FEED") ||
    die "Invalid appcast on latest release $PREVIOUS_TAG."
  [[ "$PREVIOUS_BUILD" =~ '^[1-9][0-9]*$' ]] || die "Invalid Sparkle build number on latest release $PREVIOUS_TAG."
  if (( ${#BUILD} < ${#PREVIOUS_BUILD} )) || { (( ${#BUILD} == ${#PREVIOUS_BUILD} )) && [[ ! "$BUILD" > "$PREVIOUS_BUILD" ]]; }; then
    die "Build $BUILD must be higher than the current appcast build $PREVIOUS_BUILD ($PREVIOUS_TAG)."
  fi
else
  print "No appcast on the latest release; skipping the previous-build check."
fi

print "Creating a draft and uploading both assets…"
gh release create "$TAG" "$ZIP" "$APPCAST" --repo "$GITHUB_REPO" --target "$COMMIT" --draft \
  --title "$TITLE" --notes-file - <<< "$NOTES" ||
  die "Draft creation or upload failed. Check $REPO_URL/releases for an incomplete draft before retrying."

DRAFT=$(release_ids) || die "Could not verify the draft for $TAG. Inspect it on GitHub before retrying."
[[ "$DRAFT" =~ '^[0-9]+$' ]] || die "Expected a single draft for $TAG. Inspect releases before retrying."
check_remote_tag
# GitHub ignores target_commitish when the tag already exists; its commit was just verified.
TARGET_CHECK="(.target_commitish == \"$COMMIT\")"
[[ -z "$REMOTE_TAG_COMMIT" ]] || TARGET_CHECK=true
DRAFT_OK=$(gh_api "$API_REPO/releases/$DRAFT" --jq ".draft and (.tag_name == \"$TAG\") and $TARGET_CHECK and (
  any(.assets[]; .state == \"uploaded\" and .name == \"$ZIP_NAME\" and .size == $ZIP_SIZE and .digest == \"$ZIP_DIGEST\") and
  any(.assets[]; .state == \"uploaded\" and .name == \"appcast.xml\" and .size == $APPCAST_SIZE and .digest == \"$APPCAST_DIGEST\")
)") || die "Could not verify uploaded assets. $TAG was left as a draft."
[[ "$DRAFT_OK" == true ]] || die "Draft or uploaded assets do not match the prepared release. $TAG was not published."

print "Publishing $TAG as the latest release…"
gh_api "$API_REPO/releases/$DRAFT" --method PATCH -F draft=false -f make_latest=true --jq .html_url ||
  die "Could not confirm publication. Inspect $REPO_URL/releases before retrying."
