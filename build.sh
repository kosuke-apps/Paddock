#!/bin/bash
# Assembles Paddock.app. There is no Xcode project on purpose: this script is the whole build definition.
#
#   ./build.sh            build ./Paddock.app
#   ./build.sh --install  build, then copy it to /Applications (a running copy is quit first)
#   ./build.sh --release  build, then zip it into dist/
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP="Paddock.app"
BUNDLE_ID="dev.kosuke.paddock"
TARGET="arm64-apple-macos26.0"
# The one certificate shared by every Mac Utilities app. See ../SpellBar/docs/code-signing.md.
SIGNING_IDENTITY_NAME="Mac Utilities Code Signing"

INSTALL=0
RELEASE=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --release) RELEASE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p build

echo "▸ Icon"
if [ ! -f Resources/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  xcrun swift tools/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

echo "▸ Compiling"
rm -rf "$APP" build/strings
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/strings
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The compiler also writes out every string passed to String(localized:), with its format specifiers.
xcrun swiftc -O -swift-version 6 -target "$TARGET" \
  -emit-localized-strings -emit-localized-strings-path build/strings \
  -o "$APP/Contents/MacOS/Paddock" \
  Sources/Core/*.swift Sources/App/*.swift

echo "▸ Strings"
# User-facing strings live in the String Catalog. Bring it in line with the code, the way Xcode does on build,
# then refuse to finish while a string lacks its Japanese translation or is no longer used.
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata build/strings/*.stringsdata
xcrun swift tools/check_strings.swift Resources/Localizable.xcstrings ja
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources"

echo "▸ Signing"
# macOS remembers privacy permissions and login items by the app's designated requirement. Signed ad-hoc, that
# requirement is the binary's hash and changes with every build; signed with the certificate, it is the
# certificate plus the bundle identifier and stays the same.
#
# `security find-identity` without -v also lists a self-signed certificate the system does not trust. That is
# enough: neither codesign nor the permission database needs the certificate to be trusted.
hashes=$(security find-identity -p codesigning 2>/dev/null \
  | awk -v name="\"$SIGNING_IDENTITY_NAME\"" 'index($0, name) { print $2 }' | sort -u)
count=$(printf '%s' "$hashes" | grep -c . || true)
if [ "$count" -eq 1 ]; then
  codesign --force --sign "$hashes" --identifier "$BUNDLE_ID" "$APP"
  echo "  signed with \"$SIGNING_IDENTITY_NAME\" ($hashes)"
elif [ "$count" -gt 1 ]; then
  echo "error: $count identities are named \"$SIGNING_IDENTITY_NAME\"; keep one in Keychain Access" >&2
  exit 1
else
  echo "warning: \"$SIGNING_IDENTITY_NAME\" is not in the keychain; signing ad-hoc instead." >&2
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
echo "▸ Built: $(pwd)/$APP"

if [ "$INSTALL" = 1 ]; then
  echo "▸ Installing to /Applications"
  # Paddock treats SIGTERM as Quit, so a server it started is stopped before the copy is replaced.
  if pkill -TERM -x Paddock; then
    for _ in $(seq 1 60); do
      pgrep -x Paddock >/dev/null || break
      sleep 0.5
    done
    if pgrep -x Paddock >/dev/null; then
      echo "error: Paddock is still running; quit it and run again" >&2
      exit 1
    fi
  fi
  rm -rf "/Applications/$APP"
  ditto "$APP" "/Applications/$APP"
  echo "▸ Installed: /Applications/$APP"
fi

if [ "$RELEASE" = 1 ]; then
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
  mkdir -p dist
  zip="dist/Paddock-$version.zip"
  rm -f "$zip"
  # ditto keeps the bundle's signature intact; zip(1) does not.
  ditto -c -k --keepParent "$APP" "$zip"
  echo "▸ Packaged: $(pwd)/$zip"
fi
