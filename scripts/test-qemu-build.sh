#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Dynamically resolve the directory containing this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building custom QEMU with anti-detection patches..."

# Run nix-build using the absolute path to the .nix file
# The -o flag forces the output symlink (usually 'result') to be placed in the scripts directory
nix-build "$SCRIPT_DIR/test-qemu-build.nix" -K -o "$SCRIPT_DIR/result"

echo ""
echo "✅ Build successful! The patched QEMU binary is available at:"
echo "   $SCRIPT_DIR/result/bin/qemu-system-x86_64"
