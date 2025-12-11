#!/bin/sh

# Polar Cloud Klipper Integration Uninstaller for Creality K1/K1C/K1 Max

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# K1 specific paths
INSTALL_DIR="/usr/data/polar-cloud-klipper"
PRINTER_DATA_DIR="/usr/data/printer_data"
MOONRAKER_COMPONENTS="/usr/data/moonraker/moonraker/components"

print_header() {
    echo "${BLUE}=====================================${NC}"
    echo "${BLUE}  Polar Cloud K1 Uninstaller${NC}"
    echo "${BLUE}=====================================${NC}"
    echo ""
}

print_success() {
    echo "${GREEN}✓ $1${NC}"
}

print_error() {
    echo "${RED}✗ $1${NC}"
}

print_warning() {
    echo "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo "${BLUE}ℹ $1${NC}"
}

# Main uninstall function
uninstall() {
    print_header

    print_warning "This will remove the Polar Cloud integration from your K1 printer."
    printf "Are you sure you want to continue? (y/N) "
    read REPLY
    case "$REPLY" in
        [Yy]*)
            ;;
        *)
            print_info "Uninstall cancelled."
            exit 0
            ;;
    esac

    # Stop service
    print_info "Stopping Polar Cloud service..."
    if [ -f "/usr/data/polar_cloud_service.sh" ]; then
        /usr/data/polar_cloud_service.sh stop 2>/dev/null || true
    fi
    print_success "Service stopped"

    # Remove service scripts
    if [ -f "/etc/init.d/S99polar_cloud" ]; then
        rm -f /etc/init.d/S99polar_cloud
        print_success "Removed startup script"
    fi

    if [ -f "/usr/data/polar_cloud_service.sh" ]; then
        rm -f /usr/data/polar_cloud_service.sh
        print_success "Removed service script"
    fi

    # Remove PID file
    rm -f /var/run/polar_cloud.pid 2>/dev/null || true

    # Remove Moonraker plugin
    if [ -f "$MOONRAKER_COMPONENTS/polar_cloud.py" ]; then
        rm -f "$MOONRAKER_COMPONENTS/polar_cloud.py"
        print_success "Removed Moonraker plugin"
    fi

    # Ask about configuration file
    print_warning "Configuration file contains your Polar Cloud credentials and registration."
    echo "Choose an option:"
    echo "1) Keep configuration and registration (quick reconnect)"
    echo "2) Keep credentials but clear registration (show registration process)"
    echo "3) Remove all configuration and credentials"
    printf "Select option (1/2/3): "
    read REPLY

    config_file="$PRINTER_DATA_DIR/config/polar_cloud.conf"

    if [ -f "$config_file" ]; then
        case "$REPLY" in
            1)
                print_info "Configuration file preserved (will reconnect immediately)"
                ;;
            2)
                # Remove just the serial number to force re-registration
                sed -i '/^serial_number/d' "$config_file"
                print_success "Cleared registration info"
                ;;
            3)
                rm -f "$config_file"
                print_success "Removed all configuration"
                ;;
            *)
                print_info "Invalid option, keeping configuration file unchanged"
                ;;
        esac
    else
        print_info "No configuration file found"
    fi

    # Clean up moonraker.conf entries
    moonraker_conf="$PRINTER_DATA_DIR/config/moonraker.conf"
    if [ -f "$moonraker_conf" ]; then
        print_info "Cleaning up moonraker.conf..."

        # Backup
        cp "$moonraker_conf" "${moonraker_conf}.polar_backup"

        # Remove polar_cloud section
        sed -i '/\[polar_cloud\]/,/^$/d' "$moonraker_conf" 2>/dev/null || true

        # Remove update_manager polar_cloud section
        sed -i '/\[update_manager polar_cloud\]/,/^$/d' "$moonraker_conf" 2>/dev/null || true

        print_success "Cleaned up moonraker.conf"
    fi

    # Remove nginx configuration (restore backup if exists)
    nginx_configs="/usr/data/nginx/nginx/sites/fluidd.conf /etc/nginx/sites-enabled/fluidd /etc/nginx/nginx.conf"
    for conf in $nginx_configs; do
        if [ -f "${conf}.polar_backup" ]; then
            cp "${conf}.polar_backup" "$conf"
            rm -f "${conf}.polar_backup"
            print_success "Restored nginx configuration from backup"
            break
        fi
    done

    # Reload nginx
    /etc/init.d/S50nginx restart 2>/dev/null || nginx -s reload 2>/dev/null || true

    # Remove Polar Cloud directory
    printf "Remove Polar Cloud installation directory? (y/N) "
    read REPLY
    case "$REPLY" in
        [Yy]*)
            if [ -d "$INSTALL_DIR" ]; then
                rm -rf "$INSTALL_DIR"
                print_success "Removed Polar Cloud directory"
            fi
            ;;
        *)
            print_info "Keeping installation directory at $INSTALL_DIR"
            ;;
    esac

    # Restart Moonraker
    print_info "Restarting Moonraker..."
    /etc/init.d/S56moonraker_service restart 2>/dev/null || \
    /usr/data/moonraker/scripts/moonraker-start.sh restart 2>/dev/null || \
    killall -HUP moonraker 2>/dev/null || true
    print_success "Moonraker restarted"

    print_info ""
    print_success "Polar Cloud integration has been removed from your K1 printer."
    print_info ""
}

# Run uninstall
uninstall
