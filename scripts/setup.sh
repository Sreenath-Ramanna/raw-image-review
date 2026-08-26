#!/usr/bin/env bash
# scripts/setup.sh — one-shot setup for raw_viewer on Fedora/Ubuntu
set -euo pipefail

DISTRO=$(. /etc/os-release && echo "$ID")

echo "==> Installing system dependencies..."
if [[ "$DISTRO" == "fedora" ]]; then
    # Note: Fedora spells it "LibRaw-devel" (capitalised) — "libraw-devel" does
    # not exist, and "libraw1394-devel" is FireWire, not the RAW decoder.
    # "pkg-config" is likewise only a virtual provide; the package is pkgconf-pkg-config.
    sudo dnf install -y \
        LibRaw-devel \
        cmake \
        ninja-build \
        gtk3-devel \
        clang \
        pkgconf-pkg-config
elif [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
    sudo apt-get update && sudo apt-get install -y \
        libraw-dev \
        cmake \
        ninja-build \
        libgtk-3-dev \
        clang \
        pkg-config
else
    echo "Unsupported distro: $DISTRO — install LibRaw headers, cmake, ninja and gtk3 dev packages manually."
fi

echo "==> Getting Flutter packages..."
flutter pub get

echo "==> Done. Run:  flutter run -d linux"
