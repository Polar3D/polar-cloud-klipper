#!/bin/sh

# Polar Cloud Klipper Integration Installer for Creality K1/K1C/K1 Max
# This script is specifically designed for the Creality K1 series firmware environment

set -e

# Colors for output (compatible with busybox ash)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# K1 specific paths
INSTALL_DIR="/usr/data/polar-cloud-klipper"
PRINTER_DATA_DIR="/usr/data/printer_data"
MOONRAKER_DIR="/usr/data/moonraker"
MOONRAKER_COMPONENTS="/usr/data/moonraker/moonraker/components"
VENV_DIR="$INSTALL_DIR/venv"

# Configuration
POLAR_SERVER="https://printer4.polar3d.com"
DEFAULT_REPO="https://github.com/Polar3D/polar-cloud-klipper.git"

print_header() {
    echo "${BLUE}=====================================${NC}"
    echo "${BLUE}  Polar Cloud K1 Series Installer${NC}"
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

# Check if running on K1 series
check_k1_environment() {
    print_info "Checking K1 series environment..."

    if [ ! -d "/usr/data" ]; then
        print_error "This script is specifically for Creality K1/K1C/K1 Max printers"
        print_info "For other Klipper installations, use: ./install.sh"
        exit 1
    fi

    # Check for Moonraker
    if [ ! -d "$MOONRAKER_DIR" ]; then
        print_error "Moonraker not found at $MOONRAKER_DIR"
        print_info "Please ensure Moonraker is installed on your K1"
        exit 1
    fi

    # Check for printer_data
    if [ ! -d "$PRINTER_DATA_DIR" ]; then
        print_error "printer_data not found at $PRINTER_DATA_DIR"
        exit 1
    fi

    print_success "K1 series environment detected"
}

# Check and install dependencies via Entware
check_dependencies() {
    print_info "Checking dependencies..."

    # Check for Python3
    if ! command -v python3 >/dev/null 2>&1; then
        print_error "Python3 not found!"
        print_info "Python3 should be pre-installed on K1 firmware"
        exit 1
    fi
    print_success "Found: python3"

    # Check for virtualenv
    if [ ! -f "/usr/bin/virtualenv" ]; then
        print_warning "virtualenv not found, checking for venv module..."
        if ! python3 -m venv --help >/dev/null 2>&1; then
            print_error "Neither virtualenv nor venv module found!"
            print_info "Try installing Entware and run: /opt/bin/opkg install python3-venv"
            exit 1
        fi
        VENV_CMD="python3 -m venv"
    else
        # Check if virtualenv has correct shebang
        if head -1 /usr/bin/virtualenv | grep -q "python$"; then
            print_warning "Fixing virtualenv shebang for Python3..."
            sed -i '1s|#!/usr/bin/python|#!/usr/bin/python3|' /usr/bin/virtualenv
        fi
        VENV_CMD="virtualenv -p /usr/bin/python3 --system-site-packages"
    fi
    print_success "Found: virtualenv"

    # Check for git
    if ! command -v git >/dev/null 2>&1; then
        print_warning "Git not found, attempting to install via Entware..."
        if [ -x "/opt/bin/opkg" ]; then
            /opt/bin/opkg update
            /opt/bin/opkg install git git-http
        else
            print_error "Git not found and Entware not available"
            print_info "Please install Entware first, then install git:"
            print_info "  /opt/bin/opkg install git git-http"
            exit 1
        fi
    fi
    print_success "Found: git"

    # nginx is pre-installed on K1 with Fluidd
    if ! command -v nginx >/dev/null 2>&1; then
        print_warning "nginx not found - web interface may not be accessible"
    else
        print_success "Found: nginx"
    fi

    print_success "All dependencies satisfied"
}

# Create directories
create_directories() {
    print_info "Setting up directories..."

    # The script directory should already be the install dir if cloned properly
    if [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
        if [ -d "$INSTALL_DIR" ]; then
            print_info "Existing installation found at $INSTALL_DIR"
        else
            print_info "Copying files to $INSTALL_DIR..."
            cp -r "$SCRIPT_DIR" "$INSTALL_DIR"
        fi
    fi

    # Create web directory
    mkdir -p "$INSTALL_DIR/web"

    # Ensure config directory exists
    mkdir -p "$PRINTER_DATA_DIR/config"

    # Ensure logs directory exists
    mkdir -p "$PRINTER_DATA_DIR/logs"

    print_success "Directories ready"
}

# Install Python virtual environment
install_venv() {
    print_info "Setting up Python virtual environment..."

    # Create virtual environment
    if [ -d "$VENV_DIR" ]; then
        print_info "Removing existing virtual environment..."
        rm -rf "$VENV_DIR"
    fi

    $VENV_CMD "$VENV_DIR"

    # Upgrade pip
    "$VENV_DIR/bin/pip" install --upgrade pip 2>/dev/null || "$VENV_DIR/bin/pip3" install --upgrade pip

    # Install requirements
    if [ -f "$INSTALL_DIR/requirements.txt" ]; then
        "$VENV_DIR/bin/pip" install -r "$INSTALL_DIR/requirements.txt" 2>/dev/null || \
        "$VENV_DIR/bin/pip3" install -r "$INSTALL_DIR/requirements.txt"
        print_success "Installed Python dependencies"
    else
        print_error "requirements.txt not found in $INSTALL_DIR"
        exit 1
    fi
}

# Install files
install_files() {
    print_info "Installing Polar Cloud files..."

    # Copy Moonraker plugin
    if [ -d "$MOONRAKER_COMPONENTS" ]; then
        cp "$INSTALL_DIR/src/polar_cloud_moonraker.py" "$MOONRAKER_COMPONENTS/polar_cloud.py"
        print_success "Installed Moonraker plugin"
    else
        print_error "Moonraker components directory not found: $MOONRAKER_COMPONENTS"
        exit 1
    fi

    # Copy web interface
    cp "$INSTALL_DIR/src/polar_cloud_web.html" "$INSTALL_DIR/web/index.html"
    print_success "Installed web interface"

    # Copy configuration template if no config exists
    if [ ! -f "$PRINTER_DATA_DIR/config/polar_cloud.conf" ]; then
        cp "$INSTALL_DIR/config/polar_cloud.conf.template" "$PRINTER_DATA_DIR/config/polar_cloud.conf"
        print_success "Created configuration file"
    else
        print_info "Configuration file already exists, skipping"
    fi
}

# Install service using K1's init system
install_service() {
    print_info "Installing Polar Cloud service..."

    # K1 uses a custom init system - create service script
    SERVICE_SCRIPT="/usr/data/polar_cloud_service.sh"

    cat > "$SERVICE_SCRIPT" << EOF
#!/bin/sh
# Polar Cloud Service Script for K1

POLAR_DIR="$INSTALL_DIR"
PIDFILE="/var/run/polar_cloud.pid"
LOGFILE="$PRINTER_DATA_DIR/logs/polar_cloud.log"

start() {
    if [ -f "\$PIDFILE" ] && kill -0 \$(cat "\$PIDFILE") 2>/dev/null; then
        echo "Polar Cloud is already running"
        return 1
    fi
    echo "Starting Polar Cloud..."
    cd "\$POLAR_DIR"
    nohup "\$POLAR_DIR/venv/bin/python" "\$POLAR_DIR/src/polar_cloud.py" >> "\$LOGFILE" 2>&1 &
    echo \$! > "\$PIDFILE"
    echo "Polar Cloud started (PID: \$(cat \$PIDFILE))"
}

stop() {
    if [ -f "\$PIDFILE" ]; then
        echo "Stopping Polar Cloud..."
        kill \$(cat "\$PIDFILE") 2>/dev/null
        rm -f "\$PIDFILE"
        echo "Polar Cloud stopped"
    else
        echo "Polar Cloud is not running"
    fi
}

restart() {
    stop
    sleep 2
    start
}

status() {
    if [ -f "\$PIDFILE" ] && kill -0 \$(cat "\$PIDFILE") 2>/dev/null; then
        echo "Polar Cloud is running (PID: \$(cat \$PIDFILE))"
    else
        echo "Polar Cloud is not running"
        rm -f "\$PIDFILE" 2>/dev/null
    fi
}

case "\$1" in
    start)   start ;;
    stop)    stop ;;
    restart) restart ;;
    status)  status ;;
    *)       echo "Usage: \$0 {start|stop|restart|status}" ;;
esac
EOF

    chmod +x "$SERVICE_SCRIPT"
    print_success "Created service script: $SERVICE_SCRIPT"

    # Add to startup - K1 uses /etc/init.d style
    INIT_SCRIPT="/etc/init.d/S99polar_cloud"

    cat > "$INIT_SCRIPT" << EOF
#!/bin/sh
# Polar Cloud startup script

case "\$1" in
    start)
        /usr/data/polar_cloud_service.sh start
        ;;
    stop)
        /usr/data/polar_cloud_service.sh stop
        ;;
    restart)
        /usr/data/polar_cloud_service.sh restart
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart}"
        exit 1
        ;;
esac
EOF

    chmod +x "$INIT_SCRIPT"
    print_success "Created startup script: $INIT_SCRIPT"
}

# Configure Moonraker
configure_moonraker() {
    print_info "Configuring Moonraker..."

    local moonraker_conf="$PRINTER_DATA_DIR/config/moonraker.conf"

    if [ ! -f "$moonraker_conf" ]; then
        print_warning "moonraker.conf not found at $moonraker_conf"
        print_info "You may need to manually add [polar_cloud] section"
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
path: $INSTALL_DIR
origin: $DEFAULT_REPO
primary_branch: main
managed_services: polar_cloud
install_script: install_k1.sh
EOF
        print_success "Added update manager configuration"
    else
        print_info "Update manager already configured for Polar Cloud"
    fi
}

# Configure nginx
configure_nginx() {
    print_info "Configuring nginx for Polar Cloud web interface..."

    # K1 nginx config is typically at /usr/data/nginx/nginx/nginx.conf
    # or /etc/nginx/nginx.conf
    local nginx_conf=""
    local nginx_configs="/usr/data/nginx/nginx/sites/fluidd.conf /etc/nginx/sites-enabled/fluidd /etc/nginx/nginx.conf"

    for conf in $nginx_configs; do
        if [ -f "$conf" ]; then
            nginx_conf="$conf"
            print_info "Found nginx configuration: $conf"
            break
        fi
    done

    if [ -z "$nginx_conf" ]; then
        print_warning "Could not find nginx configuration"
        print_info "You may need to manually configure nginx for the web interface"
        print_info "The Polar Cloud web interface is at: $INSTALL_DIR/web/"
        return
    fi

    # Check if already configured
    if grep -q "polar-cloud" "$nginx_conf"; then
        print_info "Nginx already configured for Polar Cloud"
        return
    fi

    # Backup original
    cp "$nginx_conf" "${nginx_conf}.polar_backup"

    # For K1, we need to add a location block
    # This is a simplified approach - insert before the last }

    local nginx_snippet="
    # Polar Cloud web interface
    location = /polar-cloud {
        return 301 \$scheme://\$host/polar-cloud/;
    }

    location /polar-cloud/ {
        alias $INSTALL_DIR/web/;
        try_files \$uri \$uri/ /polar-cloud/index.html;
    }
"

    # Try to add the configuration
    # Find the server block and add before the closing brace
    if grep -q "server {" "$nginx_conf"; then
        # Use sed to insert before the last closing brace of server block
        # This is a simplified approach
        sed -i "/^[[:space:]]*location.*{/,/^[[:space:]]*}/ {
            /^[[:space:]]*}/ {
                i\\
$nginx_snippet
            }
        }" "$nginx_conf" 2>/dev/null || {
            # Fallback: append to file and let nginx figure it out
            print_warning "Could not automatically configure nginx"
            print_info "Please manually add this to your nginx server block:"
            echo "$nginx_snippet"
        }
    fi

    # Test and reload nginx
    if nginx -t 2>/dev/null; then
        /etc/init.d/S50nginx restart 2>/dev/null || nginx -s reload 2>/dev/null || true
        print_success "Nginx configuration updated"
    else
        print_warning "Nginx configuration test failed, restoring backup"
        cp "${nginx_conf}.polar_backup" "$nginx_conf"
        print_info "You may need to manually configure nginx"
    fi
}

# Start services
start_services() {
    print_info "Starting services..."

    # Restart Moonraker to load plugin
    print_info "Restarting Moonraker..."
    /etc/init.d/S56moonraker_service restart 2>/dev/null || \
    /usr/data/moonraker/scripts/moonraker-start.sh restart 2>/dev/null || \
    killall -HUP moonraker 2>/dev/null || true

    sleep 3
    print_success "Moonraker restarted"

    # Start Polar Cloud service
    print_info "Starting Polar Cloud service..."
    /usr/data/polar_cloud_service.sh start

    sleep 2
    if /usr/data/polar_cloud_service.sh status | grep -q "running"; then
        print_success "Polar Cloud service started"
    else
        print_warning "Polar Cloud service may not have started properly"
        print_info "Check logs at: $PRINTER_DATA_DIR/logs/polar_cloud.log"
    fi
}

# Print final instructions
print_instructions() {
    local ip_addr
    ip_addr=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}')

    echo ""
    print_header
    print_success "Polar Cloud installation complete!"
    echo ""
    print_info "Next steps:"
    echo "1. Navigate to http://${ip_addr:-your-printer-ip}/polar-cloud/"
    echo "2. Enter your Polar Cloud credentials"
    echo "3. Select your printer type and configure settings"
    echo ""
    print_info "Useful commands:"
    echo "• Check service status: /usr/data/polar_cloud_service.sh status"
    echo "• View logs: tail -f $PRINTER_DATA_DIR/logs/polar_cloud.log"
    echo "• Restart service: /usr/data/polar_cloud_service.sh restart"
    echo ""
    print_info "To uninstall:"
    echo "• Run: $INSTALL_DIR/uninstall_k1.sh"
    echo ""
}

# Main installation flow
main() {
    print_header

    check_k1_environment
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
