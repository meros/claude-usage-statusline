#!/usr/bin/env bash
# install.sh - Non-Nix installer for claude-usage-statusline
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/share/claude-usage-statusline}"
BIN_DIR="${BIN_DIR:-${HOME}/.local/bin}"

echo "claude-usage-statusline installer"
echo "================================="
echo ""

# Check dependencies
missing=()
for cmd in jq curl bc; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing dependencies: ${missing[*]}"
    echo "Please install them first."
    exit 1
fi

# Clone or update
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "Updating existing installation..."
    git -C "$INSTALL_DIR" pull --ff-only
else
    if [ -d "$INSTALL_DIR" ]; then
        echo "Directory $INSTALL_DIR exists but is not a git repo."
        echo "Remove it first or set INSTALL_DIR to a different path."
        exit 1
    fi
    echo "Cloning to $INSTALL_DIR..."
    git clone "https://github.com/meros/claude-usage-statusline.git" "$INSTALL_DIR"
fi

# Symlink
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/bin/claude-usage" "$BIN_DIR/claude-usage"
chmod +x "$INSTALL_DIR/bin/claude-usage"

echo ""
echo "Installed successfully!"
echo "  Binary: $BIN_DIR/claude-usage"
echo ""

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -q "^${BIN_DIR}$"; then
    echo "NOTE: $BIN_DIR is not in your PATH."
    echo "Add to your shell profile:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    echo ""
fi

echo "To configure Claude Code statusline:"
echo "  claude-usage install-hook"
