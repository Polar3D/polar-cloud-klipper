#!/bin/sh
set -e

# Configuration
REPO_URL="https://github.com/Polar3D/polar-cloud-klipper.git"

# Determine install directory
if [ -d "/usr/data" ]; then
    # Creality K1/K1C/K1 Max
    INSTALL_DIR="/usr/data/polar-cloud-klipper"
elif [ -n "$HOME" ]; then
    INSTALL_DIR="${HOME}/polar-cloud-klipper"
else
    INSTALL_DIR="/home/$(whoami)/polar-cloud-klipper"
fi

echo "------------------------------------------------"
echo "  Polar Cloud Klipper Bootstrap Installer"
echo "------------------------------------------------"
echo "Install directory: $INSTALL_DIR"

# 1. Check if git is installed
if ! command -v git >/dev/null 2>&1; then
    echo "Git is not installed. Attempting to install..."
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y git
    elif command -v opkg >/dev/null 2>&1; then
        opkg update && opkg install git git-http
    else
        echo "ERROR: Git is not installed and no package manager found."
        echo "Please install git manually and try again."
        exit 1
    fi
fi

# 2. Clone or Update the Repository
if [ -d "$INSTALL_DIR" ]; then
    echo "Existing installation found. Updating..."
    cd "$INSTALL_DIR"
    git reset --hard
    git pull
else
    echo "Cloning Polar Cloud repository..."
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# 3. Hand off to the appropriate installer
echo "Starting installation..."

# Detect K1/K1C/K1 Max and use appropriate installer
if [ -d "/usr/data" ]; then
    echo "Creality K1 series detected - using K1-specific installer..."
    chmod +x install_k1.sh
    ./install_k1.sh
else
    chmod +x install.sh
    ./install.sh
fi