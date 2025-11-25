#!/bin/bash
set -e

# Configuration
REPO_URL="https://github.com/Polar3D/polar-cloud-klipper.git"
INSTALL_DIR="${HOME}/polar-cloud-klipper"

echo "------------------------------------------------"
echo "  Polar Cloud Klipper Bootstrap Installer"
echo "------------------------------------------------"

# 1. Check if git is installed
if ! command -v git &> /dev/null; then
    echo "Git is not installed. Installing git..."
    sudo apt-get update && sudo apt-get install -y git
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

# 3. Hand off to the actual installer
echo "Starting installation..."
chmod +x install.sh
./install.sh