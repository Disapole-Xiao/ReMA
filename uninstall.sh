#!/usr/bin/env bash
# rema uninstall script
# Safely removes rema installation (symlink, config) without touching shared data.
set -euo pipefail

CONFIG_FILE="$HOME/.rema_config"
INSTALL_DIR="$HOME/.local/bin"
REMA_SYMLINK="$INSTALL_DIR/rema"

echo "=== rema uninstaller ==="
echo ""
echo "Stop local ReMA workers with 'rema stop <name>' before uninstalling."
echo ""

# 1. Workers are stopped explicitly with `rema stop <name>` on their own host.
# Shared state does not identify a local process safely enough to stop it here.

# 2. Remove symlink
if [ -L "$REMA_SYMLINK" ] || [ -f "$REMA_SYMLINK" ]; then
  rm -f "$REMA_SYMLINK"
  echo "Removed: $REMA_SYMLINK"
else
  echo "Symlink not found: $REMA_SYMLINK"
fi

# 3. Remove config file
if [ -f "$CONFIG_FILE" ]; then
  # Read REMA_DIR before deleting config
  rema_dir=$(grep "^REMA_DIR=" "$CONFIG_FILE" | cut -d= -f2- || echo "")
  rm -f "$CONFIG_FILE"
  echo "Removed: $CONFIG_FILE"
fi

# 4. Clean .bashrc entries (only lines we added)
if [ -f "$HOME/.bashrc" ]; then
  grep -n "^# rema$\|^source.*rema_config$\|^export PATH=.*\\.local/bin" "$HOME/.bashrc" | while IFS=: read -r line_num content; do
    echo "  Removing line $line_num from ~/.bashrc: $content"
  done
  # Remove our block: "# rema" + following line
  tmp=$(mktemp)
  while IFS= read -r line; do
    if [ "$line" = "# rema" ]; then
      continue  # skip this line
    fi
    if echo "$line" | grep -qE '^(source|\.).*rema_config$|^export PATH=.*\.local/bin'; then
      continue  # skip our added lines
    fi
    echo "$line" >> "$tmp"
  done < "$HOME/.bashrc"
  mv "$tmp" "$HOME/.bashrc"
  echo "Cleaned ~/.bashrc"
fi

echo ""
echo "=== Uninstall complete ==="
echo ""

if [ -n "${rema_dir:-}" ]; then
  echo "NOTE: Shared data directory was NOT removed:"
  echo "  $rema_dir"
  echo "This contains machine state, logs, and worker data."
  echo "Delete manually if you are sure no other machines are using it:"
  echo "  rm -rf $rema_dir"
else
  echo "Config file was already gone. Shared data directory (if any) was not removed."
fi
