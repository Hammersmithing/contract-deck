#!/bin/zsh
# Build Contract Deck and install to /Applications, then launch.
set -e
cd "$(dirname "$0")"
xcodegen
xcodebuild -scheme ContractDeck -configuration Release -derivedDataPath build build
osascript -e 'tell application "Contract Deck" to quit' 2>/dev/null || true
sleep 1
[ -d "/Applications/Contract Deck.app" ] && mv "/Applications/Contract Deck.app" ~/.Trash/"Contract Deck-$(date +%s).app"
ditto "build/Build/Products/Release/Contract Deck.app" "/Applications/Contract Deck.app"
open "/Applications/Contract Deck.app"
