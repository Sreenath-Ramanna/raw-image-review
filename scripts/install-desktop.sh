#!/usr/bin/env bash
# Registers the app with the desktop: menu entry plus icon.
#
# This is what makes the icon appear under Wayland. A Wayland compositor
# ignores gtk_window_set_icon_list() and instead matches the window's app id
# against a .desktop file, taking the icon from there — so without this the
# window falls back to a generic placeholder no matter what the code does.
# On X11 the in-process icon works on its own, but installing is still what
# gives you a menu entry.
#
#   ./scripts/install-desktop.sh            # install
#   ./scripts/install-desktop.sh --uninstall
#
# Everything lands under ~/.local/share; no root needed.
set -euo pipefail

APP_ID="com.example.raw_viewer"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS="$DATA/applications"
ICONS="$DATA/icons/hicolor"
SIZES=(16 24 32 48 64 128 256 512)

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -fv "$APPS/$APP_ID.desktop"
    for s in "${SIZES[@]}"; do
        rm -fv "$ICONS/${s}x${s}/apps/$APP_ID.png"
    done
    gtk-update-icon-cache -f -t "$ICONS" 2>/dev/null || true
    update-desktop-database "$APPS" 2>/dev/null || true
    echo "==> Uninstalled."
    exit 0
fi

# Prefer release; fall back to debug so this works mid-development.
EXEC=""
for variant in release debug; do
    candidate="$REPO/build/linux/x64/$variant/bundle/raw_viewer"
    if [[ -x "$candidate" ]]; then
        EXEC="$candidate"
        break
    fi
done
if [[ -z "$EXEC" ]]; then
    echo "No built binary found. Run:  flutter build linux --release" >&2
    exit 1
fi

echo "==> Installing icons into $ICONS"
for s in "${SIZES[@]}"; do
    src="$REPO/assets/icon/app_icon_$s.png"
    [[ -f "$src" ]] || continue
    install -Dm644 "$src" "$ICONS/${s}x${s}/apps/$APP_ID.png"
done

echo "==> Installing $APP_ID.desktop into $APPS"
mkdir -p "$APPS"
sed "s|@EXEC@|$EXEC|" "$REPO/linux/packaging/$APP_ID.desktop" \
    > "$APPS/$APP_ID.desktop"
chmod 644 "$APPS/$APP_ID.desktop"

gtk-update-icon-cache -f -t "$ICONS" 2>/dev/null || true
update-desktop-database "$APPS" 2>/dev/null || true

echo "==> Done. Launching from the menu now uses:"
echo "    $EXEC"
echo
echo "Re-run this after moving or rebuilding the bundle elsewhere;"
echo "the .desktop file records an absolute path."
