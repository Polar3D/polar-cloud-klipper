#!/bin/bash

# Polar Cloud Klipper Integration Uninstaller

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${BLUE}  Polar Cloud Uninstaller${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Main uninstall function
uninstall() {
    print_header
    
    print_warning "This will remove the Polar Cloud integration from your system."
    read -p "Are you sure you want to continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Uninstall cancelled."
        exit 0
    fi
    
    # Stop and disable service
    print_info "Stopping Polar Cloud service..."
    sudo systemctl stop polar_cloud 2>/dev/null || true
    sudo systemctl disable polar_cloud 2>/dev/null || true
    print_success "Service stopped and disabled"
    
    # Remove service file
    if [ -f "/etc/systemd/system/polar_cloud.service" ]; then
        sudo rm /etc/systemd/system/polar_cloud.service
        sudo systemctl daemon-reload
        print_success "Removed systemd service"
    fi
    
    # Find user home directory
    if systemctl is-active --quiet klipper 2>/dev/null; then
        USER=$(systemctl show -p User --value klipper)
    fi
    
    if [ -z "$USER" ]; then
        for test_user in pi klipper ubuntu debian; do
            if id "$test_user" &>/dev/null; then
                USER="$test_user"
                break
            fi
        done
    fi
    
    if [ -z "$USER" ]; then
        read -p "Enter the system user: " USER
    fi
    
    HOME_DIR=$(eval echo "~$USER")
    
    # Remove Polar Cloud directory
    if [ -d "$HOME_DIR/polar-cloud" ]; then
        rm -rf "$HOME_DIR/polar-cloud"
        print_success "Removed Polar Cloud directory"
    fi
    
    # Remove Moonraker plugin
    local moonraker_dirs=(
        "$HOME_DIR/moonraker/moonraker/components/polar_cloud.py"
        "/opt/moonraker/moonraker/components/polar_cloud.py"
    )
    
    for file in "${moonraker_dirs[@]}"; do
        if [ -f "$file" ]; then
            sudo rm "$file"
            print_success "Removed Moonraker plugin"
            break
        fi
    done
    
    # Ask about configuration file
    print_warning "Configuration file contains your Polar Cloud credentials."
    read -p "Remove configuration file? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ -f "$HOME_DIR/printer_data/config/polar_cloud.conf" ]; then
            rm "$HOME_DIR/printer_data/config/polar_cloud.conf"
            print_success "Removed configuration file"
        elif [ -f "$HOME_DIR/klipper_config/polar_cloud.conf" ]; then
            rm "$HOME_DIR/klipper_config/polar_cloud.conf"
            print_success "Removed configuration file"
        fi
    else
        print_info "Configuration file preserved"
    fi
    
    # Restart Moonraker
    if systemctl is-active --quiet moonraker; then
        print_info "Restarting Moonraker..."
        sudo systemctl restart moonraker
        print_success "Moonraker restarted"
    fi
    
    print_info ""
    print_success "Polar Cloud integration has been removed."
    print_info ""
    print_warning "Note: nginx configuration was not modified."
    print_info "You may want to manually remove the /polar-cloud/ location block"
    print_info "from your nginx configuration if desired."
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Please run this script as a normal user, not as root!"
    exit 1
fi

uninstall