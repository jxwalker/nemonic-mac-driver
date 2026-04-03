#!/bin/bash
set -e
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MODULE_CACHE_PATH="/tmp/nemonic-clang-module-cache"

echo "Installing Nemonic Fun Scripts..."
echo "================================="

echo "1. Compiling native text-to-pdf renderer..."
SDK_PATH="$(xcrun --show-sdk-path)"
mkdir -p "$MODULE_CACHE_PATH"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_PATH" swiftc -sdk "$SDK_PATH" "$SCRIPT_DIR/texttopng.swift" -o "$SCRIPT_DIR/nemonic_texttopng" -O

if [ "$EUID" -ne 0 ]; then
  echo "2. Installing renderer to /usr/local/bin (requires sudo)..."
  sudo mkdir -p /usr/local/bin
  sudo cp "$SCRIPT_DIR/nemonic_texttopng" /usr/local/bin/nemonic_texttopng
  sudo chmod 755 /usr/local/bin/nemonic_texttopng
else
  echo "2. Installing renderer to /usr/local/bin..."
  mkdir -p /usr/local/bin
  cp "$SCRIPT_DIR/nemonic_texttopng" /usr/local/bin/nemonic_texttopng
  chmod 755 /usr/local/bin/nemonic_texttopng
fi

echo "3. Copying aliases to ~/.nemonic_aliases.zsh..."
cp "$SCRIPT_DIR/nemonic_aliases.zsh" ~/.nemonic_aliases.zsh

echo "4. Adding source command to ~/.zshrc..."
touch ~/.zshrc
if ! grep -q "nemonic_aliases.zsh" ~/.zshrc; then
    echo "" >> ~/.zshrc
    echo "# Load Nemonic Printer Shortcuts" >> ~/.zshrc
    echo "source ~/.nemonic_aliases.zsh" >> ~/.zshrc
    echo "Added to ~/.zshrc!"
else
    echo "Aliases already present in ~/.zshrc."
fi

echo ""
echo "Installation complete! Open a new terminal window or type 'source ~/.zshrc' to use your new commands:"
echo "- todo \"Buy milk\" \"Call mom\""
echo "- focus \"Refactor the database\""
echo "- weather \"London\""
echo "- ticket 123"
echo "- joke"
