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
    read -p "Are you sure you want to continue? (y/N) " REPLY
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Uninstall cancelled."
        exit 0
    fi

    # Prompt for sudo password upfront to avoid issues later
    print_info "Requesting sudo access..."
    sudo -v || { print_error "Failed to obtain sudo access"; exit 1; }

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
        for test_user in pi mks klipper ubuntu debian; do
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
    
    # Ask about configuration file and registration
    print_warning "Configuration file contains your Polar Cloud credentials and registration."
    echo "Choose an option:"
    echo "1) Keep configuration and registration (quick reconnect)"
    echo "2) Keep credentials but clear registration (show registration process)"
    echo "3) Remove all configuration and credentials"
    read -p "Select option (1/2/3): " REPLY
    
    config_file=""
    if [ -f "$HOME_DIR/printer_data/config/polar_cloud.conf" ]; then
        config_file="$HOME_DIR/printer_data/config/polar_cloud.conf"
    elif [ -f "$HOME_DIR/klipper_config/polar_cloud.conf" ]; then
        config_file="$HOME_DIR/klipper_config/polar_cloud.conf"
    fi
    
    if [ -n "$config_file" ]; then
        case $REPLY in
            1)
                print_info "Configuration file preserved (will reconnect immediately)"
                ;;
            2)
                # Remove just the serial number to force re-registration
                # Note: Same MAC address will get same serial number from Polar Cloud
                sed -i '/^serial_number/d' "$config_file"
                print_success "Cleared registration info (will re-register with same serial number)"
                ;;
            3)
                rm "$config_file"
                print_success "Removed all configuration"
                ;;
            *)
                print_info "Invalid option, keeping configuration file unchanged"
                ;;
        esac
    else
        print_info "No configuration file found"
    fi
    
    # Remove nginx configuration
    print_info "Cleaning up nginx configuration..."
    
    # Check for standalone Polar Cloud nginx config first
    if [ -f "/etc/nginx/sites-enabled/polar-cloud" ]; then
        sudo rm -f /etc/nginx/sites-enabled/polar-cloud
        sudo rm -f /etc/nginx/sites-available/polar-cloud
        print_success "Removed standalone Polar Cloud nginx configuration"
    else
        # Check common nginx configs for Polar Cloud entries
        local nginx_configs=(
            "/etc/nginx/sites-available/mainsail"
            "/etc/nginx/sites-available/fluidd"
            "/etc/nginx/conf.d/mainsail.conf"
            "/etc/nginx/conf.d/fluidd.conf"
            "/etc/nginx/sites-enabled/mainsail"
            "/etc/nginx/sites-enabled/fluidd"
        )
        
        local cleaned=false
        for conf in "${nginx_configs[@]}"; do
            if [ -f "$conf" ] && grep -q "location.*polar-cloud" "$conf"; then
                # Create backup
                sudo cp "$conf" "${conf}.backup.before_polar_removal.$(date +%Y%m%d_%H%M%S)"
                
                # Remove Polar Cloud configuration block
                sudo sed -i '/# Polar Cloud nginx configuration snippet/,/^[[:space:]]*}[[:space:]]*$/d' "$conf" 2>/dev/null || true
                sudo sed -i '/location.*polar-cloud/,/^[[:space:]]*}[[:space:]]*$/d' "$conf" 2>/dev/null || true
                
                if ! grep -q "location.*polar-cloud" "$conf"; then
                    print_success "Removed Polar Cloud configuration from $conf"
                    cleaned=true
                else
                    print_warning "Could not fully remove Polar Cloud config from $conf"
                fi
                break
            fi
        done
        
        if [ "$cleaned" = false ]; then
            print_info "No nginx configuration changes needed"
        fi
    fi
    
    # Test and reload nginx if it's running
    if systemctl is-active --quiet nginx; then
        if sudo nginx -t 2>/dev/null; then
            sudo systemctl reload nginx
            print_success "Nginx configuration reloaded"
        else
            print_error "Nginx configuration test failed - check your nginx config"
        fi
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
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Please run this script as a normal user, not as root!"
    exit 1
fi

uninstall