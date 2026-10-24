#!/bin/bash
# Publish a notarized BetterCast.dmg to the in-app updater (Sparkle).
#
#   scripts/publish_mac_update.sh v22            # after make_app.sh has notarized BetterCast.dmg
#   scripts/publish_mac_update.sh v22 --dry-run  # write appcast.xml, upload nothing
#
# 1. Uploads BetterCast.dmg to the GitHub release <tag> (which must already exist,
#    with its notes; this script doesn't create the main release).
# 2. Signs the DMG with the EdDSA key in the login keychain (account "bettercast",
#    made by Sparkle's generate_keys; its public half is SUPublicEDKey in Info.plist).
# 3. Writes appcast.xml and uploads it to the `mac-updates` release, which every
#    Sparkle-enabled build reads. That release is a pre-release on purpose: it must
#    never become "latest", which older builds' checker and the website rely on.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: $0 <release-tag> [--dry-run]}"
DRY_RUN="${2:-}"
REPO="StephenLovino/BetterCast"
FEED_TAG="mac-updates"
DMG="BetterCast.dmg"
APP="BetterCast.app"
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"

[ -f "$DMG" ] && [ -d "$APP" ] || { echo "error: run make_app.sh (with notarization) first" >&2; exit 1; }
[ -x "$SIGN_UPDATE" ] || swift package resolve >/dev/null
xcrun stapler validate "$DMG" >/dev/null || { echo "error: $DMG is not notarized and stapled" >&2; exit 1; }

BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")

# sign_update prints: sparkle:edSignature="..." length="..."
SIG_ATTRS=$("$SIGN_UPDATE" --account bettercast "$DMG")
URL="https://github.com/$REPO/releases/download/$TAG/$DMG"
NOTES="https://github.com/$REPO/releases/tag/$TAG"
PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>BetterCast</title>
    <item>
      <title>BetterCast $TAG</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$NOTES</sparkle:fullReleaseNotesLink>
      <sparkle:releaseNotesLink>$NOTES</sparkle:releaseNotesLink>
      <enclosure url="$URL" type="application/octet-stream" $SIG_ATTRS />
    </item>
  </channel>
</rss>
EOF
xmllint --noout appcast.xml
echo "appcast.xml: $TAG, build $BUILD ($SHORT), min macOS $MIN_OS"

if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "Dry run: nothing uploaded."
    exit 0
fi

gh release view "$TAG" -R "$REPO" >/dev/null || { echo "error: create release $TAG first" >&2; exit 1; }
gh release upload "$TAG" "$DMG" --clobber -R "$REPO"

if ! gh release view "$FEED_TAG" -R "$REPO" >/dev/null 2>&1; then
    gh release create "$FEED_TAG" -R "$REPO" --prerelease --latest=false \
        --title "Mac update feed" \
        --notes "Feed for BetterCast's in-app updater. Not a release; download BetterCast from the latest release instead."
fi
gh release upload "$FEED_TAG" appcast.xml --clobber -R "$REPO"
echo "Published: Sparkle-enabled builds will offer $TAG."
