#!/bin/sh
# Makes a Swiftr release that people can download and open: builds a commit
# for Apple silicon and Intel Macs, signs it with the team's Developer ID,
# has Apple notarize it, and packs it in a disk image. With --publish, it
# puts that image in a GitHub release, with the feed that tells installed
# copies about it (appcast.xml), and updates the Homebrew cask.
#
#     scripts/release.sh 0.2.0            # build/dist/0.2.0/Swiftr-0.2.0.dmg
#     scripts/release.sh 0.2.0 --publish  # the same, then the release and the cask
#
# --publish after a plain run publishes the image already made, if it was
# made from the same commit. SWIFTR_REF picks the commit (HEAD by default):
# what isn't committed isn't in the release.
#
# A release tells what it brings: write release-notes/<version>.txt before
# --publish. The GitHub release shows these notes, and so does Swiftr when
# it offers the update. Up to three sections, in this order, each a heading
# alone on its line, then one "• " line per change; leave out a section with
# nothing in it:
#
#     What's New
#     • Swiftr › Check for Updates… updates Swiftr, herdr-core and your models.
#
#     Improvements
#     • Long conversations scroll faster.
#
#     Bug Fixes
#     • A long paste no longer loses its last line.
#
# Needs:
# - Xcode, XcodeGen (brew install xcodegen), the team's ID in
#   `git config swiftr.team` (or SWIFTR_TEAM), and the team's "Developer ID
#   Application" certificate in the login keychain. Run the script from a
#   terminal of your login session (Terminal.app works): codesign needs the
#   keychain.
# - An App Store Connect API key, for notarizing: by default the one asc
#   (brew install asc) signs in with, read from
#   ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8. SWIFTR_NOTARY_KEY_ID,
#   SWIFTR_NOTARY_ISSUER and SWIFTR_NOTARY_KEY (the .p8 file) name another.
# - A key that signs updates, so that installed copies trust them (Swiftr ›
#   Check for Updates…, through Sparkle). Make it once with Sparkle's
#   generate_keys, which the script names when the key is missing: it keeps
#   the key in your login keychain. Save a copy somewhere safe
#   (generate_keys -x <file>): copies already installed take updates signed
#   with this key only.
# - The feed's address, built into the app: by default the appcast.xml of
#   the latest GitHub release of this clone's origin. SWIFTR_FEED_URL names
#   another.
# - For --publish: gh, signed in to the account that owns the repo (origin)
#   and its tap, <owner>/homebrew-tap; the commit already pushed.
set -eu

usage() {
    echo "usage: scripts/release.sh <version, like 0.2.0> [--publish]" >&2
    exit 2
}
say() { printf '\n== %s\n' "$*"; }
fail() {
    echo "release: $*" >&2
    exit 1
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
version=$1
publish=0
if [ $# = 2 ]; then
    [ "$2" = --publish ] || usage
    publish=1
fi
case $version in
    "" | *[!0-9.]* | .* | *. | *..*) fail "a version is numbers and dots, like 0.2.0" ;;
esac

cd "$(dirname "$0")/.."
root=$(pwd)
ref=${SWIFTR_REF:-HEAD}
sha=$(git rev-parse --verify --quiet "$ref^{commit}") || fail "no commit $ref"
build=$(git rev-list --count "$sha")
out="$root/build/dist/$version"
app="$out/export/Swiftr.app"
dmg="$out/Swiftr-$version.dmg"

# Signing: the team's Developer ID Application certificate.
team=${SWIFTR_TEAM:-$(git config --get swiftr.team || true)}
[ -n "$team" ] || fail "no team: git config swiftr.team <TEAM_ID>"
identity=$(security find-identity -v -p codesigning | sed -n "s/.*\"\(Developer ID Application: .*($team)\)\".*/\1/p" | head -1)
[ -n "$identity" ] || fail "no \"Developer ID Application\" certificate of team $team in the keychain (Xcode › Settings › Accounts › Manage Certificates)"
if ! security find-certificate -c "$identity" -p | openssl x509 -noout -checkend 5184000 > /dev/null; then
    ends=$(security find-certificate -c "$identity" -p | openssl x509 -noout -enddate | cut -d= -f2)
    echo "warning: \"$identity\" expires $ends; make a new one before then." >&2
fi

# Notarizing: an App Store Connect API key.
key_id=${SWIFTR_NOTARY_KEY_ID:-}
issuer=${SWIFTR_NOTARY_ISSUER:-}
if command -v asc > /dev/null 2>&1; then
    [ -n "$key_id" ] || key_id=$(asc auth status 2> /dev/null | sed -n 's/.*"keyId":"\([^"]*\)","isDefault":true.*/\1/p')
    [ -n "$issuer" ] || issuer=$(asc auth issuer-id 2> /dev/null || true)
fi
key=${SWIFTR_NOTARY_KEY:-$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8}
[ -n "$key_id" ] && [ -n "$issuer" ] && [ -f "$key" ] ||
    fail "no App Store Connect API key to notarize with: sign in with asc (asc auth login …), or set SWIFTR_NOTARY_KEY_ID, SWIFTR_NOTARY_ISSUER and SWIFTR_NOTARY_KEY"
notary() { xcrun notarytool "$@" --key "$key" --key-id "$key_id" --issuer "$issuer"; }

# Updates: where installed copies look for newer releases.
slug=$(git remote get-url origin 2> /dev/null | sed -n 's#^.*github\.com[:/]\(.*\)$#\1#p' | sed 's#\.git$##')
feed=${SWIFTR_FEED_URL:-${slug:+https://github.com/$slug/releases/latest/download/appcast.xml}}
[ -n "$feed" ] || fail "no address for the update feed: origin isn't on GitHub, so set SWIFTR_FEED_URL"
# Sparkle's tools come with its package, once Xcode has fetched it.
sparkle="$root/build/SourcePackages/artifacts/sparkle/Sparkle/bin"

# Publishing: checked before a long build.
if [ "$publish" = 1 ]; then
    command -v gh > /dev/null 2>&1 || fail "--publish needs gh (brew install gh)"
    repo=$(gh repo view --json nameWithOwner -q .nameWithOwner) || fail "no GitHub repo for this clone's origin"
    owner=${repo%%/*}
    tap="$owner/homebrew-tap"
    gh api "repos/$repo/commits/$sha" > /dev/null 2>&1 || fail "$(git rev-parse --short "$sha") isn't on GitHub: push it first"
    if gh release view "v$version" --repo "$repo" > /dev/null 2>&1; then fail "v$version is already released"; fi
    gh repo view "$tap" > /dev/null 2>&1 || fail "no tap: gh repo create $tap --public"
fi

# The release's notes, written by hand. Prints what is wrong with them,
# nothing when they are fine.
notes="$root/release-notes/$version.txt"
notes_problem() {
    [ -f "$notes" ] || {
        echo "no notes for $version: write $notes (the top of this script shows how)"
        return
    }
    awk '
        function bad(why) { if (!said) print FILENAME ", line " NR ": " why; said = 1 }
        { sub(/\r$/, "") }
        /^[ \t]*$/ { next }
        $0 == "What'\''s New" || $0 == "Improvements" || $0 == "Bug Fixes" {
            rank = $0 == "What'\''s New" ? 1 : $0 == "Improvements" ? 2 : 3
            if (rank <= last) bad("the sections go in this order, once each: What'\''s New, Improvements, Bug Fixes")
            if (last && !items) bad("the section before \"" $0 "\" is empty")
            last = rank
            items = 0
            next
        }
        /^• [^ ]/ {
            if (!last) bad("a change before any heading")
            items++
            next
        }
        { bad("neither a heading (What'\''s New, Improvements, Bug Fixes) nor a \"• \" line") }
        END {
            if (said) exit
            if (!last) print FILENAME ": no section"
            else if (!items) print FILENAME ": the last section is empty"
        }
    ' "$notes"
}
# The notes as Markdown, which GitHub and the feed take.
notes_markdown() {
    sed -E -e "s/$(printf '\r')\$//" -e 's/[<>]/\\&/g' -e 's/^• /- /' -e "s/^(What's New|Improvements|Bug Fixes)\$/## \\1/" "$notes"
}
if [ "$publish" = 1 ]; then
    problem=$(notes_problem)
    [ -z "$problem" ] || fail "$problem"
fi

# Sends a file to Apple's notary service and waits for its answer.
submit() {
    result=$(notary submit "$1" --wait --output-format json 2>&1) || true
    id=$(printf '%s\n' "$result" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | tail -1)
    status=$(printf '%s\n' "$result" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p' | tail -1)
    if [ "$status" != Accepted ]; then
        if [ -n "$id" ]; then notary log "$id" "$out/notary-$id.json" > /dev/null 2>&1 || true; fi
        fail "Apple didn't notarize $(basename "$1") (${status:-no answer}): $result${id:+ — its log: $out/notary-$id.json}"
    fi
    echo "Notarized: $(basename "$1")"
}

make_release() {
    rm -rf "$out"
    mkdir -p "$out/src"
    say "Swiftr $version ($build) from $(git log -1 --format='%h %s' "$sha")"
    git archive "$sha" | tar -x -C "$out/src"
    xcodegen=$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)
    [ -x "$xcodegen" ] || fail "XcodeGen is missing: brew install xcodegen"
    (cd "$out/src" && "$xcodegen" generate --quiet)

    log="$out/build.log"
    xcodebuild -resolvePackageDependencies -project "$out/src/Swiftr.xcodeproj" -scheme Swiftr \
        -derivedDataPath "$out/derived" -clonedSourcePackagesDirPath "$root/build/SourcePackages" \
        > "$log" 2>&1 || fail "the packages didn't resolve, see $log"
    [ -x "$sparkle/generate_keys" ] && [ -x "$sparkle/sign_update" ] || fail "Sparkle's tools aren't in $sparkle"
    update_key=$("$sparkle/generate_keys" -p 2> /dev/null) ||
        fail "no key to sign updates with. Make one, once: $sparkle/generate_keys (then save a copy: generate_keys -x <file>)"

    say "Building, signed by $identity"
    if ! xcodebuild archive -project "$out/src/Swiftr.xcodeproj" -scheme Swiftr -configuration Release \
        -archivePath "$out/Swiftr.xcarchive" -derivedDataPath "$out/derived" \
        -clonedSourcePackagesDirPath "$root/build/SourcePackages" \
        -destination "generic/platform=macOS" -skipPackagePluginValidation -skipMacroValidation \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
        DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
        SWIFTR_FEED_URL="$feed" SWIFTR_UPDATE_KEY="$update_key" \
        >> "$log" 2>&1; then
        grep -E "error:|BUILD FAILED" "$log" | head -20 >&2
        fail "the build failed, see $log"
    fi
    cat > "$out/export.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$team</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF
    xcodebuild -exportArchive -archivePath "$out/Swiftr.xcarchive" -exportPath "$out/export" \
        -exportOptionsPlist "$out/export.plist" >> "$log" 2>&1 || fail "the export failed, see $log"

    # One architecture per check: this lipo takes only one after -verify_arch.
    for arch in arm64 x86_64; do
        lipo "$app/Contents/MacOS/Swiftr" -verify_arch "$arch" || fail "the app has no $arch code"
    done
    codesign --verify --deep --strict "$app" || fail "the app's signature doesn't hold"
    info=$(codesign -dvv "$app" 2>&1)
    case "$info" in *"Authority=Developer ID Application"*"TeamIdentifier=$team"*) ;; *) fail "not signed with the team's Developer ID: $info" ;; esac
    case "$info" in *"(runtime)"*) ;; *) fail "the hardened runtime is off, and Apple won't notarize it" ;; esac
    plist() { /usr/libexec/PlistBuddy -c "Print $1" "$app/Contents/Info.plist" 2> /dev/null; }
    [ "$(plist SUFeedURL)" = "$feed" ] && [ "$(plist SUPublicEDKey)" = "$update_key" ] ||
        fail "the app doesn't carry the update feed and key: it couldn't update itself"

    say "Notarizing the app (a few minutes)"
    ditto -c -k --keepParent "$app" "$out/Swiftr.zip"
    submit "$out/Swiftr.zip"
    xcrun stapler staple -q "$app"

    say "Disk image"
    mkdir -p "$out/dmg"
    ditto "$app" "$out/dmg/Swiftr.app"
    ln -s /Applications "$out/dmg/Applications"
    if diskutil image create from --help > /dev/null 2>&1; then
        diskutil image create from --format UDZO --volumeName Swiftr "$out/dmg" "$dmg" > /dev/null
    else
        hdiutil create -volname Swiftr -srcfolder "$out/dmg" -format UDZO -ov "$dmg" > /dev/null
    fi
    codesign --sign "$identity" --timestamp "$dmg"
    submit "$dmg"
    xcrun stapler staple -q "$dmg"
    spctl --assess --type open --context context:primary-signature "$dmg" 2> /dev/null || fail "Gatekeeper refuses $dmg"
    spctl --assess --type execute "$app" 2> /dev/null || fail "Gatekeeper refuses $app"

    # What Sparkle checks before it installs the image: last, since
    # stapling changed the file.
    say "Signing the update"
    "$sparkle/sign_update" -p "$dmg" > "$out/signature" || fail "the update key didn't sign $dmg"
    [ -s "$out/signature" ] || fail "the update key gave no signature"
    echo "$sha" > "$out/commit"
}

# The feed installed copies read: this release alone, with what it brings.
# $1 is the notes, in Markdown.
write_appcast() {
    system=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$app/Contents/Info.plist")
    {
        cat << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Swiftr</title>
        <item>
            <title>Swiftr $version</title>
            <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <sparkle:version>$build</sparkle:version>
            <sparkle:shortVersionString>$version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$system</sparkle:minimumSystemVersion>
            <sparkle:fullReleaseNotesLink>https://github.com/$repo/releases</sparkle:fullReleaseNotesLink>
EOF
        printf '            <description sparkle:format="markdown"><![CDATA['
        # "]]>" would end the block early.
        sed 's/]]>/]]]]><![CDATA[>/g' "$1"
        cat << EOF
]]></description>
            <enclosure url="https://github.com/$repo/releases/download/v$version/Swiftr-$version.dmg" length="$(stat -f %z "$dmg")" type="application/octet-stream" sparkle:edSignature="$(cat "$out/signature")"/>
        </item>
    </channel>
</rss>
EOF
    } > "$out/appcast.xml"
}

if [ "$publish" = 1 ] && [ -f "$dmg" ] && [ -s "$out/signature" ] && [ "$(cat "$out/commit" 2> /dev/null)" = "$sha" ]; then
    say "Publishing the image made earlier: $dmg"
else
    make_release
fi
sha256=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
if [ "$publish" = 0 ]; then
    say "Done: $dmg"
    echo "sha256: $sha256"
    echo "Open it on another Mac to check it, then: scripts/release.sh $version --publish"
    problem=$(notes_problem)
    [ -z "$problem" ] || echo "Before that, the release's notes: $problem"
    exit 0
fi

say "GitHub release v$version in $repo"
# The same notes for the release and for the feed.
notes_markdown > "$out/notes.md"
write_appcast "$out/notes.md"
gh release create "v$version" "$dmg" "$out/appcast.xml" --repo "$repo" --target "$sha" --title "Swiftr $version" --notes-file "$out/notes.md"

say "Homebrew cask in $tap"
bundle_id=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$app/Contents/Info.plist")
rm -rf "$out/tap"
gh repo clone "$tap" "$out/tap" -- --quiet
mkdir -p "$out/tap/Casks"
cat > "$out/tap/Casks/swiftr.rb" << EOF
cask "swiftr" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/$repo/releases/download/v#{version}/Swiftr-#{version}.dmg"
  name "Swiftr"
  desc "Terminals and coding agents on every machine"
  homepage "https://github.com/$repo"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :tahoe"

  app "Swiftr.app"

  zap trash: [
    "~/Library/Application Support/Swiftr",
    "~/Library/Caches/$bundle_id",
    "~/Library/Preferences/$bundle_id.plist",
  ]
end
EOF
if command -v brew > /dev/null 2>&1; then
    brew style --fix "$out/tap/Casks/swiftr.rb" > /dev/null || fail "brew style finds problems in $out/tap/Casks/swiftr.rb"
fi
git -C "$out/tap" add Casks/swiftr.rb
git -C "$out/tap" commit --quiet -m "swiftr $version"
git -C "$out/tap" push --quiet
say "Published"
echo "https://github.com/$repo/releases/tag/v$version"
echo "brew install --cask $(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')/tap/swiftr"
