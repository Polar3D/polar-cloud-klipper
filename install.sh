#!/bin/bash

# Polar Cloud Klipper Integration Installer
# Compatible with Mainsail, Fluidd, and other Klipper web interfaces

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
USER=""
HOME_DIR=""
POLAR_DIR=""
PRINTER_DATA_DIR=""
MOONRAKER_DIR=""
MOONRAKER_COMPONENTS=""
VENV_DIR=""

# Configuration
POLAR_SERVER="https://printer4.polar3d.com"
DEFAULT_REPO="https://github.com/Polar3D/polar-cloud-klipper.git"

# Functions
print_header() {
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${BLUE}  Polar Cloud Klipper Installer${NC}"
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

# Detect system user
detect_user() {
    print_info "Detecting system configuration..."
    
    # Try to find the user running Klipper
    if systemctl is-active --quiet klipper; then
        KLIPPER_USER=$(systemctl show -p User --value klipper)
        if [ -n "$KLIPPER_USER" ] && [ "$KLIPPER_USER" != "root" ]; then
            USER="$KLIPPER_USER"
        fi
    fi
    
    # Common default users
    if [ -z "$USER" ]; then
        for test_user in pi klipper ubuntu debian; do
            if id "$test_user" &>/dev/null; then
                USER="$test_user"
                break
            fi
        done
    fi
    
    # Ask user if we couldn't detect
    if [ -z "$USER" ]; then
        read -p "Enter the system user running Klipper: " USER
    fi
    
    # Verify user exists
    if ! id "$USER" &>/dev/null; then
        print_error "User '$USER' does not exist!"
        exit 1
    fi
    
    HOME_DIR=$(eval echo "~$USER")
    print_success "Detected user: $USER"
    print_success "Home directory: $HOME_DIR"
}

# Detect Klipper installation
detect_klipper() {
    print_info "Looking for Klipper installation..."
    
    # Check for printer_data (newer structure)
    if [ -d "$HOME_DIR/printer_data" ]; then
        PRINTER_DATA_DIR="$HOME_DIR/printer_data"
        print_success "Found printer_data directory: $PRINTER_DATA_DIR"
    # Check for klipper_config (older structure)
    elif [ -d "$HOME_DIR/klipper_config" ]; then
        PRINTER_DATA_DIR="$HOME_DIR/klipper_config"
        print_warning "Found legacy klipper_config directory: $PRINTER_DATA_DIR"
        print_info "Note: Consider migrating to the newer printer_data structure"
    else
        print_error "Could not find Klipper configuration directory!"
        read -p "Enter the path to your Klipper config directory: " PRINTER_DATA_DIR
        if [ ! -d "$PRINTER_DATA_DIR" ]; then
            print_error "Directory does not exist: $PRINTER_DATA_DIR"
            exit 1
        fi
    fi
    
    # Ensure config subdirectory exists
    if [ ! -d "$PRINTER_DATA_DIR/config" ]; then
        mkdir -p "$PRINTER_DATA_DIR/config"
        print_info "Created config directory"
    fi
    
    # Ensure logs subdirectory exists
    if [ ! -d "$PRINTER_DATA_DIR/logs" ]; then
        mkdir -p "$PRINTER_DATA_DIR/logs"
        print_info "Created logs directory"
    fi
}

# Detect Moonraker installation
detect_moonraker() {
    print_info "Looking for Moonraker installation..."
    
    # Common Moonraker locations
    MOONRAKER_DIRS=(
        "$HOME_DIR/moonraker"
        "/opt/moonraker"
        "$HOME_DIR/klipper_env/lib/python*/site-packages/moonraker"
    )
    
    for dir in "${MOONRAKER_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            MOONRAKER_DIR="$dir"
            break
        fi
    done
    
    if [ -z "$MOONRAKER_DIR" ]; then
        print_error "Could not find Moonraker installation!"
        read -p "Enter the path to your Moonraker directory: " MOONRAKER_DIR
        if [ ! -d "$MOONRAKER_DIR" ]; then
            print_error "Directory does not exist: $MOONRAKER_DIR"
            exit 1
        fi
    fi
    
    # Find components directory
    if [ -d "$MOONRAKER_DIR/moonraker/components" ]; then
        MOONRAKER_COMPONENTS="$MOONRAKER_DIR/moonraker/components"
    elif [ -d "$MOONRAKER_DIR/components" ]; then
        MOONRAKER_COMPONENTS="$MOONRAKER_DIR/components"
    else
        print_error "Could not find Moonraker components directory!"
        print_info "Looking for 'components' subdirectory in: $MOONRAKER_DIR"
        exit 1
    fi
    
    print_success "Found Moonraker: $MOONRAKER_DIR"
    print_success "Components directory: $MOONRAKER_COMPONENTS"
}

# Check and fix repository configuration
check_repositories() {
    print_info "Checking package repositories..."

    # Check if we're on Debian Buster (oldstable)
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [[ "$VERSION_CODENAME" == "buster" || "$VERSION" == *"buster"* ]]; then
            print_warning "Detected Debian Buster (oldstable)"
            print_info "Debian Buster repositories have moved to archive servers"

            # Check if repositories are already fixed
            if grep -q "archive.debian.org" /etc/apt/sources.list; then
                print_success "Archive repositories already configured"
            else
                print_info "Fixing repository configuration for Debian Buster..."

                # Backup original sources.list
                sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup

                # Update repository URLs
                sudo sed -i 's|http://deb.debian.org/debian|http://archive.debian.org/debian|g' /etc/apt/sources.list
                sudo sed -i 's|http://security.debian.org|http://archive.debian.org/debian-security|g' /etc/apt/sources.list

                print_success "Updated repository configuration for Debian Buster"
            fi
        fi
    fi
}

# Check dependencies
check_dependencies() {
    print_info "Checking system dependencies..."
    
    local deps_missing=false
    local required_packages=("python3" "python3-pip" "python3-venv" "git" "nginx")
    
    for pkg in "${required_packages[@]}"; do
        if ! command -v "$pkg" &> /dev/null && ! dpkg -l "$pkg" &> /dev/null 2>&1; then
            print_warning "Missing: $pkg"
            deps_missing=true
        else
            print_success "Found: $pkg"
        fi
    done
    
    if [ "$deps_missing" = true ]; then
        print_info "Installing missing dependencies..."

# Check repositories first
        check_repositories

        # Update package lists with error handling
        if ! sudo apt-get update; then
            print_error "Failed to update package lists!"
            print_info "This often happens on older systems where repositories have moved."
            print_info "Common fixes:"
            echo "  • For Debian Buster: repositories moved to archive.debian.org"
            echo "  • For older Ubuntu: check /etc/apt/sources.list for correct URLs"
            echo "  • Run: sudo apt-get update manually to see specific errors"
            echo ""
            print_info "Repository configuration backup saved to: /etc/apt/sources.list.backup"
            exit 1
        fi

        # Install packages with error handling
        if ! sudo apt-get install -y python3 python3-pip python3-venv git nginx; then
            print_error "Failed to install required packages!"
            print_info "Please manually install missing packages and run installer again:"
            echo "  sudo apt-get install python3 python3-pip python3-venv git nginx"
            exit 1
        fi

        # Verify installation succeeded
        local install_failed=false
        for pkg in "${required_packages[@]}"; do
            if ! command -v "$pkg" &> /dev/null && ! dpkg -l "$pkg" &> /dev/null 2>&1; then
                print_error "Package '$pkg' still missing after installation!"
                install_failed=true
            fi
        done

        if [ "$install_failed" = true ]; then
            print_error "Some packages failed to install properly"
            print_info "Please install missing packages manually and run installer again"
            exit 1
        fi

        print_success "All dependencies installed successfully"
    fi
}

# Create Polar Cloud directory structure
create_directories() {
    print_info "Creating Polar Cloud directories..."
    
    POLAR_DIR="$HOME_DIR/polar-cloud"
    VENV_DIR="$POLAR_DIR/venv"
    
    # Create directories as the target user
    sudo -u "$USER" mkdir -p "$POLAR_DIR/web"
    print_success "Created directory: $POLAR_DIR"
}

# Install Python virtual environment
install_venv() {
    print_info "Setting up Python virtual environment..."
    
    # Create virtual environment as the target user
    sudo -u "$USER" python3 -m venv "$VENV_DIR"
    
    # Upgrade pip
    sudo -u "$USER" "$VENV_DIR/bin/pip" install --upgrade pip
    
    # Install requirements
    if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
        sudo -u "$USER" "$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt"
        print_success "Installed Python dependencies"
    else
        print_error "requirements.txt not found in $SCRIPT_DIR"
        exit 1
    fi
}

# Copy and configure files
install_files() {
    print_info "Installing Polar Cloud files..."
    
    # Copy main service file
    cp "$SCRIPT_DIR/src/polar_cloud.py" "$POLAR_DIR/"
    chown "$USER:$USER" "$POLAR_DIR/polar_cloud.py"
    print_success "Installed main service"
    
    # Copy Moonraker plugin
    sudo cp "$SCRIPT_DIR/src/polar_cloud_moonraker.py" "$MOONRAKER_COMPONENTS/polar_cloud.py"
    print_success "Installed Moonraker plugin"
    
    # Copy web interface
    cp "$SCRIPT_DIR/src/polar_cloud_web.html" "$POLAR_DIR/web/index.html"
    chown -R "$USER:$USER" "$POLAR_DIR/web"
    print_success "Installed web interface"
    
    # Copy configuration template if no config exists
    if [ ! -f "$PRINTER_DATA_DIR/config/polar_cloud.conf" ]; then
        cp "$SCRIPT_DIR/config/polar_cloud.conf.template" "$PRINTER_DATA_DIR/config/polar_cloud.conf"
        chown "$USER:$USER" "$PRINTER_DATA_DIR/config/polar_cloud.conf"
        print_success "Created configuration file"
    else
        print_info "Configuration file already exists, skipping"
    fi
    
    # Copy test scripts
    if [ -d "$SCRIPT_DIR/scripts" ]; then
        cp "$SCRIPT_DIR/scripts/"*.py "$POLAR_DIR/" 2>/dev/null || true
        chown "$USER:$USER" "$POLAR_DIR/"*.py
    fi
}

# Install systemd service
install_service() {
    print_info "Installing systemd service..."
    
    # Create service file from template
    sed -e "s|{{USER}}|$USER|g" \
        -e "s|{{POLAR_DIR}}|$POLAR_DIR|g" \
        -e "s|{{PRINTER_DATA_DIR}}|$PRINTER_DATA_DIR|g" \
        "$SCRIPT_DIR/config/polar_cloud.service.template" > /tmp/polar_cloud.service
    
    # Install service
    sudo mv /tmp/polar_cloud.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable polar_cloud.service
    print_success "Installed and enabled systemd service"
}

# Configure Moonraker
configure_moonraker() {
    print_info "Configuring Moonraker..."
    
    local moonraker_conf="$PRINTER_DATA_DIR/config/moonraker.conf"
    
    if [ ! -f "$moonraker_conf" ]; then
        print_error "moonraker.conf not found at $moonraker_conf"
        return
    fi
    
    # Add Polar Cloud plugin section if it doesn't exist
    if ! grep -q "\[polar_cloud\]" "$moonraker_conf"; then
        echo "" >> "$moonraker_conf"
        echo "[polar_cloud]" >> "$moonraker_conf"
        echo "# Polar Cloud plugin configuration" >> "$moonraker_conf"
        print_success "Added Polar Cloud plugin to moonraker.conf"
    else
        print_info "Polar Cloud plugin already configured in moonraker.conf"
    fi
    
    # Add update manager section if it doesn't exist
    if ! grep -q "\[update_manager polar_cloud\]" "$moonraker_conf"; then
        echo "" >> "$moonraker_conf"
        cat >> "$moonraker_conf" << EOF
[update_manager polar_cloud]
type: git_repo
channel: stable
path: $POLAR_DIR
origin: $DEFAULT_REPO
primary_branch: main
managed_services: polar_cloud
install_script: install.sh
EOF
        print_success "Added update manager configuration to moonraker.conf"
    else
        print_info "Update manager already configured for Polar Cloud"
    fi
}

# Configure nginx
configure_nginx() {
    print_info "Configuring nginx..."
    
    # Find nginx config
    local nginx_conf=""
    if [ -f "/etc/nginx/sites-available/mainsail" ]; then
        nginx_conf="/etc/nginx/sites-available/mainsail"
        print_info "Found Mainsail nginx configuration"
    elif [ -f "/etc/nginx/sites-available/fluidd" ]; then
        nginx_conf="/etc/nginx/sites-available/fluidd"
        print_info "Found Fluidd nginx configuration"
    else
        print_warning "Could not find Mainsail or Fluidd nginx configuration"
        print_info "You'll need to manually add the nginx configuration"
        print_info "See: $SCRIPT_DIR/config/nginx-snippet.conf"
        return
    fi
    
    # Check if already configured
    if grep -q "location.*polar-cloud" "$nginx_conf"; then
        print_info "Nginx already configured for Polar Cloud"
        return
    fi
    
    # Create nginx snippet with actual path
    local nginx_snippet=$(sed "s|{{POLAR_DIR}}|$POLAR_DIR|g" "$SCRIPT_DIR/config/nginx-snippet.conf")
    
    print_info "Please add the following to your nginx configuration before the final '}':"
    echo ""
    echo "$nginx_snippet"
    echo ""
    read -p "Press Enter to continue after adding the configuration..."
    
    # Test and reload nginx
    if sudo nginx -t; then
        sudo systemctl reload nginx
        print_success "Nginx configuration updated"
    else
        print_error "Nginx configuration test failed!"
    fi
}

# Start services
start_services() {
    print_info "Starting services..."
    
    # Restart Moonraker to load plugin
    if systemctl is-active --quiet moonraker; then
        sudo systemctl restart moonraker
        print_success "Restarted Moonraker"
    fi
    
    # Start Polar Cloud service
    sudo systemctl start polar_cloud
    if systemctl is-active --quiet polar_cloud; then
        print_success "Started Polar Cloud service"
    else
        print_error "Failed to start Polar Cloud service"
        print_info "Check logs with: sudo journalctl -u polar_cloud -f"
    fi
}

# Print final instructions
print_instructions() {
    echo ""
    print_header
    print_success "Polar Cloud installation complete!"
    echo ""
    print_info "Next steps:"
    echo "1. Navigate to http://your-printer-ip/polar-cloud/"
    echo "2. Enter your Polar Cloud credentials"
    echo "3. Select your printer type and configure settings"
    echo ""
    print_info "Useful commands:"
    echo "• Check service status: sudo systemctl status polar_cloud"
    echo "• View logs: sudo journalctl -u polar_cloud -f"
    echo "• Restart service: sudo systemctl restart polar_cloud"
    echo "• Test connection: cd $POLAR_DIR && ./venv/bin/python test_socketio.py"
    echo ""
}

# Main installation flow
main() {
    print_header
    
    # Check if running as root
    if [ "$EUID" -eq 0 ]; then
        print_error "Please run this script as a normal user, not as root!"
        exit 1
    fi
    
    detect_user
    detect_klipper
    detect_moonraker
    check_dependencies
    create_directories
    install_venv
    install_files
    install_service
    configure_moonraker
    configure_nginx
    start_services
    print_instructions
}

# Run main function
main "$@"