#!/bin/sh
# Builds Swiftr in Release, installs it as ~/Applications/Swiftr.app and
# opens it. Needs Xcode and XcodeGen (brew install xcodegen).
#
# Without a team, the app is signed to run on this Mac only. To sign it with
# your Apple developer team, give the team's ID once:
#     git config swiftr.team <TEAM_ID>
# or set SWIFTR_TEAM for one run. Signing with a team needs the login
# keychain: run the script from a terminal of your login session (Terminal.app
# works), not from a shell started outside it (ssh, launchd's background).
set -eu

cd "$(dirname "$0")/.."
root=$(pwd)
derived="$root/build/release"
log="$derived/build.log"
built="$derived/Build/Products/Release/Swiftr.app"
dest="$HOME/Applications/Swiftr.app"

xcodegen=$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)
if [ ! -x "$xcodegen" ]; then
    echo "XcodeGen is missing: brew install xcodegen" >&2
    exit 1
fi
"$xcodegen" generate --quiet

team=${SWIFTR_TEAM:-$(git config --get swiftr.team || true)}
if [ -n "$team" ]; then
    set -- DEVELOPMENT_TEAM="$team" -allowProvisioningUpdates
else
    set -- CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
fi

mkdir -p "$derived"
echo "Building (Release)… log: $log"
if ! xcodebuild -project Swiftr.xcodeproj -scheme Swiftr -configuration Release \
    -derivedDataPath "$derived" -destination "platform=macOS,arch=$(uname -m)" \
    -skipPackagePluginValidation -skipMacroValidation "$@" \
    build > "$log" 2>&1; then
    grep -E "error:|errSec|BUILD FAILED" "$log" | head -20 >&2
    if grep -q errSecInternalComponent "$log"; then
        echo "The keychain refused to sign: run the script from a terminal of your login session (Terminal.app works)." >&2
    fi
    echo "Build failed, see $log" >&2
    exit 1
fi

codesign --verify --strict "$built"
info=$(codesign -dvv "$built" 2>&1)
case "$info" in
    *Signature=adhoc*) signed="signed for this Mac only" ;;
    *) signed="signed by $(printf '%s\n' "$info" | sed -n 's/^Authority=//p' | head -1)" ;;
esac

# Quit every running copy (the old install, test builds): `open` could
# otherwise bring one of them forward instead of starting the new one.
if pgrep -x Swiftr > /dev/null; then
    echo "Quitting Swiftr…"
    pkill -x Swiftr || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x Swiftr > /dev/null || break
        sleep 0.5
    done
fi

mkdir -p "$HOME/Applications"
rm -rf "$dest"
ditto "$built" "$dest"
# ditto keeps the build folder's date, which Xcode never changes, and the
# Dock caches app icons by that date: without a new one it keeps the old icon.
touch "$dest"
echo "Installed: $dest ($signed)"
open "$dest"
