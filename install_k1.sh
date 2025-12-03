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
VENV_DIR="$INSTALL_DIR/venv"

# Moonraker paths vary by K1 firmware version
# Stock firmware: /usr/share/moonraker
# Some mods: /usr/data/moonraker
MOONRAKER_DIR=""
MOONRAKER_COMPONENTS=""

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

    # Check disk space (need at least 50MB free in /usr/data)
    FREE_SPACE=$(df /usr/data 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$FREE_SPACE" ] && [ "$FREE_SPACE" -lt 51200 ]; then
        print_error "Not enough disk space in /usr/data"
        print_info "Available: $((FREE_SPACE / 1024)) MB, Required: ~50 MB"
        print_info "Try cleaning up old files or removing unused packages"
        exit 1
    fi
    print_success "Disk space check passed"

    # Find Moonraker installation - check multiple possible locations
    MOONRAKER_LOCATIONS="/usr/share/moonraker /usr/data/moonraker /usr/share/moonraker-org"
    for loc in $MOONRAKER_LOCATIONS; do
        if [ -d "$loc" ]; then
            MOONRAKER_DIR="$loc"
            print_info "Found Moonraker at: $MOONRAKER_DIR"
            break
        fi
    done

    if [ -z "$MOONRAKER_DIR" ]; then
        print_error "Moonraker not found!"
        print_info "Searched: $MOONRAKER_LOCATIONS"
        print_info "Please ensure Moonraker is installed on your K1"
        exit 1
    fi

    # Find components directory - K1 has nested structure: moonraker/moonraker/moonraker/components
    COMPONENT_PATHS="$MOONRAKER_DIR/moonraker/moonraker/components $MOONRAKER_DIR/moonraker/components $MOONRAKER_DIR/components"
    for comp_path in $COMPONENT_PATHS; do
        if [ -d "$comp_path" ]; then
            MOONRAKER_COMPONENTS="$comp_path"
            break
        fi
    done

    if [ -z "$MOONRAKER_COMPONENTS" ]; then
        print_error "Moonraker components directory not found"
        print_info "Searched paths:"
        for comp_path in $COMPONENT_PATHS; do
            print_info "  - $comp_path"
        done
        exit 1
    fi
    print_success "Found Moonraker components at: $MOONRAKER_COMPONENTS"

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

    # Create virtual environment with system site packages
    # This allows us to use system-installed cryptography if available
    if [ -d "$VENV_DIR" ]; then
        print_info "Removing existing virtual environment..."
        rm -rf "$VENV_DIR"
    fi

    $VENV_CMD "$VENV_DIR"

    # Configure pip - use /usr/data for temp files since /tmp is only 100MB RAM disk
    print_info "Configuring pip..."
    export TMPDIR="/usr/data/tmp"
    mkdir -p "$TMPDIR"

    "$VENV_DIR/bin/pip" config set global.cache-dir false 2>/dev/null || true
    "$VENV_DIR/bin/pip" install --no-cache-dir --upgrade 'pip<24' 2>/dev/null || true

    # Clean any existing pip cache to free space
    rm -rf ~/.cache/pip 2>/dev/null || true
    rm -rf /tmp/pip-* 2>/dev/null || true
    rm -rf /usr/data/tmp/pip-* 2>/dev/null || true

    # Check if system has cryptography installed
    # Also check Moonraker's virtualenv since K1 already runs Moonraker
    if python3 -c "import cryptography" 2>/dev/null; then
        print_success "Using system cryptography package"
        HAS_SYSTEM_CRYPTO=1
    elif [ -d "/usr/data/moonraker-env" ] && "/usr/data/moonraker-env/bin/python" -c "import cryptography" 2>/dev/null; then
        print_info "Found cryptography in Moonraker environment"
        # Copy from Moonraker's site-packages
        MOONRAKER_SITE=$("/usr/data/moonraker-env/bin/python" -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)
        if [ -n "$MOONRAKER_SITE" ] && [ -d "$MOONRAKER_SITE/cryptography" ]; then
            print_info "Will use Moonraker's cryptography"
            HAS_SYSTEM_CRYPTO=1
            COPY_FROM_MOONRAKER=1
        else
            HAS_SYSTEM_CRYPTO=0
        fi
    else
        HAS_SYSTEM_CRYPTO=0
        print_warning "System cryptography not found, will try to install"
    fi

    # Install requirements - use K1-specific requirements if available
    REQ_FILE="$INSTALL_DIR/requirements.txt"
    if [ -f "$INSTALL_DIR/requirements_k1.txt" ]; then
        REQ_FILE="$INSTALL_DIR/requirements_k1.txt"
        print_info "Using K1-specific requirements"
    fi

    # Install packages one by one to handle failures gracefully
    print_info "Installing Python dependencies..."

    # Core packages that should always work
    "$VENV_DIR/bin/pip" install --no-cache-dir 'python-socketio[client]>=5.0' 2>&1 || {
        print_error "Failed to install python-socketio"
        exit 1
    }

    "$VENV_DIR/bin/pip" install --no-cache-dir 'requests>=2.25' 2>&1 || {
        print_error "Failed to install requests"
        exit 1
    }

    "$VENV_DIR/bin/pip" install --no-cache-dir 'configparser>=5.0' 2>&1 || true

    "$VENV_DIR/bin/pip" install --no-cache-dir 'aiohttp>=3.7' 2>&1 || {
        print_warning "aiohttp installation had issues, continuing..."
    }

    # Pillow - may need to use system version
    "$VENV_DIR/bin/pip" install --no-cache-dir 'Pillow>=8.0' 2>&1 || {
        print_warning "Pillow pip install failed, trying system package..."
        if python3 -c "import PIL" 2>/dev/null; then
            print_success "Using system Pillow"
        else
            print_warning "Pillow not available - webcam features may not work"
        fi
    }

    # Cryptography - this is the tricky one on K1
    if [ "$HAS_SYSTEM_CRYPTO" = "1" ]; then
        if [ "$COPY_FROM_MOONRAKER" = "1" ]; then
            print_info "Copying cryptography from Moonraker environment..."
            VENV_SITE=$("$VENV_DIR/bin/python" -c "import site; print(site.getsitepackages()[0])" 2>/dev/null)
            if [ -n "$VENV_SITE" ] && [ -n "$MOONRAKER_SITE" ]; then
                cp -r "$MOONRAKER_SITE/cryptography" "$VENV_SITE/" 2>/dev/null || true
                cp -r "$MOONRAKER_SITE/cryptography"*.dist-info "$VENV_SITE/" 2>/dev/null || true
                # Also copy cffi if present (cryptography dependency)
                cp -r "$MOONRAKER_SITE/cffi" "$VENV_SITE/" 2>/dev/null || true
                cp -r "$MOONRAKER_SITE/cffi"*.dist-info "$VENV_SITE/" 2>/dev/null || true
                cp -r "$MOONRAKER_SITE/_cffi_backend"* "$VENV_SITE/" 2>/dev/null || true
            fi
        fi
        print_success "Cryptography available via system packages"
    else
        print_info "Attempting to install cryptography (this may take a while)..."
        # Try the older version that doesn't require Rust
        if ! "$VENV_DIR/bin/pip" install --no-cache-dir 'cryptography==3.3.2' 2>&1; then
            print_warning "cryptography 3.3.2 failed, trying system site-packages..."
            # Check if it's available from system
            if ! python3 -c "import cryptography" 2>/dev/null; then
                print_error "Could not install cryptography!"
                print_info ""
                print_info "The cryptography package is required but cannot be installed on K1."
                print_info "Try installing it via Entware:"
                print_info "  /opt/bin/opkg install python3-cryptography"
                print_info ""
                print_info "Or check if your K1 firmware has it pre-installed."
                exit 1
            fi
        fi
    fi

    print_success "Python dependencies installed"
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

    # Add polar_cloud to moonraker.asvc for service management permission
    local asvc_file="$PRINTER_DATA_DIR/moonraker.asvc"
    if [ -f "$asvc_file" ]; then
        if ! grep -q "polar_cloud" "$asvc_file"; then
            echo "polar_cloud" >> "$asvc_file"
            print_success "Added polar_cloud to moonraker.asvc for service management"
        fi
    else
        # Create the file if it doesn't exist
        echo "polar_cloud" > "$asvc_file"
        print_success "Created moonraker.asvc with polar_cloud service"
    fi
}

# Configure nginx
configure_nginx() {
    print_info "Configuring nginx for Polar Cloud web interface..."

    # K1 nginx config is at /usr/data/nginx/nginx/nginx.conf
    local nginx_conf=""
    local nginx_configs="/usr/data/nginx/nginx/nginx.conf /etc/nginx/nginx.conf"

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

    # K1 nginx config structure - need to add location blocks inside the server block
    # Look for the line with "location /" and insert before it

    # Create a temporary file with the new configuration
    local temp_file="/usr/data/tmp/nginx_polar_temp.conf"

    # Check if we can find a good insertion point (before "location /")
    if grep -q "location /" "$nginx_conf"; then
        # Insert the polar-cloud location blocks before the first "location /" line
        awk '
        /location \// && !inserted {
            print "        # Polar Cloud web interface"
            print "        location = /polar-cloud {"
            print "            return 301 $scheme://$host:4408/polar-cloud/;"
            print "        }"
            print ""
            print "        location /polar-cloud/ {"
            print "            alias /usr/data/polar-cloud-klipper/web/;"
            print "            index index.html;"
            print "            try_files $uri $uri/ /polar-cloud/index.html;"
            print "        }"
            print ""
            inserted = 1
        }
        { print }
        ' "$nginx_conf" > "$temp_file"

        # Check if the temp file was created properly
        if [ -s "$temp_file" ]; then
            mv "$temp_file" "$nginx_conf"
            print_success "Added Polar Cloud location blocks to nginx config"
        else
            print_warning "Failed to create nginx configuration"
            rm -f "$temp_file"
        fi
    else
        print_warning "Could not find insertion point in nginx config"
        print_info "Please manually add the following inside your server block:"
        echo ""
        echo "        # Polar Cloud web interface"
        echo "        location = /polar-cloud {"
        echo "            return 301 \$scheme://\$host:4408/polar-cloud/;"
        echo "        }"
        echo ""
        echo "        location /polar-cloud/ {"
        echo "            alias /usr/data/polar-cloud-klipper/web/;"
        echo "            index index.html;"
        echo "            try_files \$uri \$uri/ /polar-cloud/index.html;"
        echo "        }"
        return
    fi

    # Test and reload nginx
    if nginx -t 2>/dev/null; then
        # K1 uses different nginx control methods
        if [ -x "/etc/init.d/S50nginx" ]; then
            /etc/init.d/S50nginx restart 2>/dev/null
        elif [ -x "/usr/data/nginx/nginx/sbin/nginx" ]; then
            /usr/data/nginx/nginx/sbin/nginx -s reload 2>/dev/null
        else
            nginx -s reload 2>/dev/null || killall -HUP nginx 2>/dev/null || true
        fi
        print_success "Nginx configuration updated and reloaded"
    else
        print_warning "Nginx configuration test failed, restoring backup"
        cp "${nginx_conf}.polar_backup" "$nginx_conf"
        print_info "You may need to manually configure nginx"
        print_info "Please add the polar-cloud location blocks to your nginx server block"
    fi
}

# Start services
start_services() {
    print_info "Starting services..."

    # Restart Moonraker to load plugin
    print_info "Restarting Moonraker..."

    # Try multiple methods to restart Moonraker on K1
    if [ -x "/etc/init.d/S56moonraker_service" ]; then
        /etc/init.d/S56moonraker_service restart
    elif [ -x "/usr/data/moonraker/scripts/moonraker-start.sh" ]; then
        /usr/data/moonraker/scripts/moonraker-start.sh restart
    else
        # Fallback: stop and start manually
        killall moonraker 2>/dev/null || true
        sleep 2
        # Try to find and run moonraker
        if [ -f "/usr/data/moonraker-env/bin/python" ]; then
            cd /usr/data/moonraker
            nohup /usr/data/moonraker-env/bin/python -m moonraker > /dev/null 2>&1 &
        fi
    fi

    # Wait and verify Moonraker is running
    sleep 3
    if ps | grep -v grep | grep -q moonraker; then
        print_success "Moonraker is running"
    else
        print_warning "Moonraker may not have restarted properly"
        print_info "Try: /etc/init.d/S56moonraker_service start"
        print_info "Or reboot the printer after installation"
    fi

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
    echo "1. Navigate to http://${ip_addr:-your-printer-ip}:4408/polar-cloud/"
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
