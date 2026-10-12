#!/bin/zsh
# Builds Baton (Release) and packs it for friends: dist/Baton-<version>.dmg and .zip.
#   Scripts/package.sh
# Signs with a Developer ID if one exists, else Apple Development, else ad hoc ("-").
# Doesn't touch ~/Applications/Baton.app.
set -euo pipefail
root="${0:A:h}/.."
cd "$root"
root=$PWD
dist="$root/dist"
derived="$root/App/build-release"

command -v xcodegen >/dev/null || { echo "Needs xcodegen: brew install xcodegen" >&2; exit 1; }

# Pick a signing identity (only names are read, never keys).
ids=$(security find-identity -v -p codesigning 2>/dev/null || true)
if [[ $ids == *"Developer ID Application"* ]]; then
  identity="Developer ID Application"; kind="Developer ID"
elif [[ $ids == *"Apple Development"* ]]; then
  identity="Apple Development"; kind="Apple Development (not notarizable)"
else
  identity="-"; kind="ad hoc (not notarizable)"
fi
echo "→ Signing: $kind"

echo "→ Building Release…"
(cd App && xcodegen generate --quiet)
# Apple Development is the project's own setting. Overrides apply to every target (package bundles too),
# so a certificate identity also needs the team.
sign=()
[[ $identity == "-" ]] && sign+=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM="")
[[ $identity == "Developer ID Application" ]] && sign+=(CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM=UH8QWJNQQR)
# Notarization requires the hardened runtime; turn it on with a Developer ID.
[[ $identity == "Developer ID Application" ]] && sign+=(ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp)
xcodebuild -project App/Baton.xcodeproj -scheme Baton -configuration Release \
  -derivedDataPath "$derived" "${sign[@]}" -quiet build

app="$derived/Build/Products/Release/Baton.app"
[[ -d $app ]] || { echo "Build produced no app at $app" >&2; exit 1; }
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
name="Baton-$version"

echo "→ Packing $name…"
mkdir -p "$dist"
rm -f "$dist/$name.dmg" "$dist/$name.zip"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Baton.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Baton $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dist/$name.dmg" >/dev/null
ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/$name.zip"
if [[ $identity != "-" ]]; then codesign --sign "$identity" "$dist/$name.dmg"; fi

# Notarization (needs a Developer ID Application certificate from the Apple Developer Program).
# Store credentials once:  xcrun notarytool store-credentials baton-notary --apple-id <you> --team-id UH8QWJNQQR
# if [[ $identity == "Developer ID Application" ]]; then
#   xcrun notarytool submit "$dist/$name.dmg" --keychain-profile baton-notary --wait
#   xcrun stapler staple "$dist/$name.dmg"
# fi

cat <<EOF

Done:
  $dist/$name.dmg
  $dist/$name.zip

Signed: $kind. Not notarized, so on another Mac the first open needs
right-click › Open (or: xattr -dr com.apple.quarantine /Applications/Baton.app).
Send docs/INSTALL.md along with it.
EOF
