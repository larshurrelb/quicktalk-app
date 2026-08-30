#!/bin/bash
# Builds QuickTalk.app.
#
# Signing identity matters more than it looks. macOS ties Accessibility grants and
# Keychain access to the *code signature*, not to the path. An ad-hoc signature changes
# every time the code changes, so each rebuild silently invalidated both: Accessibility
# kept showing as granted in System Settings while AXIsProcessTrusted() returned false,
# and the Keychain asked for a password again on every launch.
#
# Signing with a real (even development) certificate keeps the identity stable across
# rebuilds, so permissions are granted once and stay granted.
set -euo pipefail

cd "$(dirname "$0")"

APP="QuickTalk.app"
CONTENTS="$APP/Contents"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"')

if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "⚠︎  No Apple Development certificate found — falling back to ad-hoc signing."
    echo "   Accessibility and Keychain permissions will reset on every rebuild."
    echo
fi

echo "▸ Compiling…"
swift build -c release

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp .build/release/QuickTalk "$CONTENTS/MacOS/QuickTalk"
cp Info.plist "$CONTENTS/Info.plist"
cp AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "▸ Signing as: $IDENTITY"
codesign --force --sign "$IDENTITY" --identifier com.quicktalk.QuickTalk "$APP"

# Install straight to /Applications and build nowhere else.
#
# TCC keys permissions on path *and* signature, so a second copy sitting in the build
# folder is a separate identity to macOS — it shows up as another "QuickTalk" in the
# Privacy lists, and granting the wrong one looks exactly like a permission that is
# enabled but not working.
echo "▸ Installing to /Applications…"
killall QuickTalk 2>/dev/null || true
rm -rf /Applications/QuickTalk.app
cp -R "$APP" /Applications/QuickTalk.app
rm -rf "$APP"

echo
echo "✓ Installed /Applications/QuickTalk.app"
codesign -dv /Applications/QuickTalk.app 2>&1 | grep -E "Identifier|TeamIdentifier" | sed 's/^/  /' || true
echo
echo "  Run it:  open /Applications/QuickTalk.app"
echo
echo "  If a permission reads as enabled but the app disagrees, reset and re-grant:"
echo "    tccutil reset ListenEvent com.quicktalk.QuickTalk"
