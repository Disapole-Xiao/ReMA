#!/usr/bin/env bash
# rema install script
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMA_SCRIPT="$SCRIPT_DIR/rema"
CONFIG_FILE="$HOME/.rema_config"
INSTALL_DIR="$HOME/.local/bin"
DEFAULT_REMA_DIR="$PWD/.rema"

echo "=== rema installer ==="
echo ""

# Verify rema script exists
[ ! -f "$REMA_SCRIPT" ] && { echo "Error: rema script not found at $REMA_SCRIPT"; exit 1; }

# 1. Configure REMA_DIR
if [ -f "$CONFIG_FILE" ]; then
  echo "Config file exists: $CONFIG_FILE"
  current_dir=$(grep "^REMA_DIR=" "$CONFIG_FILE" | cut -d= -f2- || echo "(not set)")
  echo "Current REMA_DIR: $current_dir"
  read -rp "Change REMA_DIR? [y/N] " change_dir
  if [ "$change_dir" = "y" ] || [ "$change_dir" = "Y" ]; then
    read -rp "Enter REMA_DIR path [$DEFAULT_REMA_DIR]: " rema_dir
    rema_dir="${rema_dir:-$DEFAULT_REMA_DIR}"
    echo "export REMA_DIR=$rema_dir" > "$CONFIG_FILE"
    echo "Updated REMA_DIR=$rema_dir"
  fi
else
  echo "REMA_DIR: shared directory for all rema data (command files, logs, state)."
  echo "Default: $DEFAULT_REMA_DIR"
  echo ""
  read -rp "Enter REMA_DIR path [$DEFAULT_REMA_DIR]: " rema_dir
  rema_dir="${rema_dir:-$DEFAULT_REMA_DIR}"
  echo "export REMA_DIR=$rema_dir" > "$CONFIG_FILE"
  echo "Created config: $CONFIG_FILE"
fi

# 2. Create symlinks
mkdir -p "$INSTALL_DIR"
ln -sf "$REMA_SCRIPT" "$INSTALL_DIR/rema"
chmod +x "$REMA_SCRIPT"

echo "Linked $INSTALL_DIR/rema -> $REMA_SCRIPT"

# 3. Check PATH
if echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  echo "$INSTALL_DIR is already in PATH"
else
  echo ""
  echo "$INSTALL_DIR is not in your PATH."
  echo "Add this to your shell config (~/.bashrc or ~/.zshrc):"
  echo ""
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
  echo ""
  read -rp "Append to ~/.bashrc now? [y/N] " append_path
  if [ "$append_path" = "y" ] || [ "$append_path" = "Y" ]; then
    echo "" >> "$HOME/.bashrc"
    echo "# rema" >> "$HOME/.bashrc"
    echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$HOME/.bashrc"
    echo "Added to ~/.bashrc"
  fi
fi

# 4. Source config in shell
if grep -qs "source.*rema_config" "$HOME/.bashrc" 2>/dev/null; then
  echo "~/.bashrc already sources rema_config"
else
  echo ""
  read -rp "Add 'source $CONFIG_FILE' to ~/.bashrc? [y/N] " append_source
  if [ "$append_source" = "y" ] || [ "$append_source" = "Y" ]; then
    echo "" >> "$HOME/.bashrc"
    echo "# rema config" >> "$HOME/.bashrc"
    echo "source $CONFIG_FILE" >> "$HOME/.bashrc"
    echo "Added to ~/.bashrc"
  fi
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "REMA_DIR: $rema_dir"
echo "Commands will be executed in the directory containing .rema/"
echo "  (i.e. $(dirname "$rema_dir"))"
echo ""
echo "To activate now, run:"
echo "  source ~/.rema_config"
echo "  source ~/.bashrc"
echo ""
echo "Usage:"
echo "  rema start <name>         Start worker on this machine"
echo "  rema run <name> -- <cmd>  Execute command on machine"
echo "  rema --help               Show all commands"
echo ""
echo "To uninstall: bash $SCRIPT_DIR/uninstall.sh"
