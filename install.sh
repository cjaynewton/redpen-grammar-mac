#!/bin/zsh
# One-command setup: the LanguageTool grammar engine (via Homebrew), then Redpen itself.
set -e
cd "${0:A:h}"
if ! command -v brew >/dev/null; then
  echo "Homebrew is needed for the grammar engine. Install it from https://brew.sh, then run this again."
  echo "(Redpen still works without it, with spelling and basic grammar only: run ./build.sh)"
  exit 1
fi
if ! brew list languagetool >/dev/null 2>&1; then
  echo "Installing LanguageTool (runs on this Mac only, port 8081)..."
  brew install languagetool
fi
# Starts now and at every login.
brew services start languagetool >/dev/null
./build.sh
open ~/Applications/"Redpen Grammar.app"
echo "Redpen is running: look for the pencil in the menu bar."
