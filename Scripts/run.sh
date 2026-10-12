#!/bin/zsh
# Builds Baton (Release: optimized, so its reading costs a fraction of a Debug build's CPU) and runs it
# from one fixed path (~/Applications/Baton.app), so macOS keeps its Accessibility permission between
# builds. Signing is the project's own (Apple Development, same team) in every configuration, so the app's
# identity, and with it the permission, is the same as the Debug builds before.
set -e
cd "$(dirname "$0")/../App"
xcodegen generate --quiet
xcodebuild -project Baton.xcodeproj -scheme Baton -configuration Release -derivedDataPath build -quiet build
pkill -x Baton 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/Baton.app
cp -R build/Build/Products/Release/Baton.app ~/Applications/Baton.app
open ~/Applications/Baton.app
echo "Baton running from ~/Applications/Baton.app"
