#!/bin/bash
# Writes Sparkle's appcast for one release. It has a single item: GitHub's
# releases/latest/download/appcast.xml always serves the newest release's, so the newest item is
# the only one an installed copy ever reads.
#
#   tools/make-appcast.sh <sign_update> <app> <zip> <download-url> <out> [notes.md]
#
# The version, build and minimum system are read back from the app's own Info.plist, so the feed
# cannot disagree with what it points at. The zip is signed with the EdDSA key in the login
# keychain (Sparkle's generate_keys); sign_update prints the enclosure's `sparkle:edSignature` and
# `length` attributes. Notes, when given and not empty, go in as Markdown
# (`sparkle:format="markdown"`), which the update window shows.
set -euo pipefail

SIGN_UPDATE="$1"; APP="$2"; ZIP="$3"; URL="$4"; OUT="$5"; NOTES="${6:-}"
[ -x "$SIGN_UPDATE" ] || { echo "appcast: no $SIGN_UPDATE" >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
BUILD=$(plutil -extract CFBundleVersion raw "$PLIST")
MINIMUM=$(plutil -extract LSMinimumSystemVersion raw "$PLIST")
SIGNATURE=$("$SIGN_UPDATE" "$ZIP")
case "$SIGNATURE" in
  *sparkle:edSignature=*) ;;
  *) echo "appcast: sign_update gave no signature: $SIGNATURE" >&2; exit 1 ;;
esac
DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

DESCRIPTION=""
if [ -n "$NOTES" ] && [ -s "$NOTES" ]; then
  # CDATA ends at the first "]]>"; notes holding one would cut the feed.
  if grep -q ']]>' "$NOTES"; then echo "appcast: the notes contain ']]>'" >&2; exit 1; fi
  DESCRIPTION="      <description sparkle:format=\"markdown\"><![CDATA[
$(cat "$NOTES")
]]></description>"
fi

cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tutamak</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
$DESCRIPTION
      <enclosure url="$URL" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT"
echo "appcast: $OUT ($VERSION, build $BUILD)"
