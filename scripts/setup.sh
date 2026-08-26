#!/usr/bin/env bash
# scripts/setup.sh — one-shot setup for raw_viewer on Fedora/Ubuntu
set -euo pipefail

DISTRO=$(. /etc/os-release && echo "$ID")

echo "==> Installing system dependencies..."
if [[ "$DISTRO" == "fedora" ]]; then
    sudo dnf install -y \
        libraw-devel \
        cmake \
        ninja-build \
        gtk3-devel \
        clang \
        pkg-config
elif [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
    sudo apt-get update && sudo apt-get install -y \
        libraw-dev \
        cmake \
        ninja-build \
        libgtk-3-dev \
        clang \
        pkg-config
else
    echo "Unsupported distro: $DISTRO — install libraw-devel, cmake, gtk3-devel manually."
fi

echo "==> Getting Flutter packages..."
flutter pub get

echo "==> Done. Run:  flutter run -d linux"
