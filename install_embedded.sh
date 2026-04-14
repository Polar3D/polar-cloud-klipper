#!/bin/sh
# Polar Cloud Klipper Integration Installer for Embedded Systems
# This script is designed for BusyBox-based systems like Anycubic Kobra S1 (Rinkhals)
# that don't have git or package managers available.
#
# Usage: curl -sSL https://raw.githubusercontent.com/Polar3D/polar-cloud-klipper/main/install_embedded.sh | sh

set -e

# Colors (may not work on all terminals)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

print_success() {
    printf "${GREEN}[OK]${NC} %s\n" "$1"
}

print_warning() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

print_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

# Detect printer data path
detect_printer_data_path() {
    # Anycubic Kobra S1 (Rinkhals)
    if [ -d "/userdata/app/gk/printer_data" ]; then
        echo "/userdata/app/gk/printer_data"
        return 0
    fi
    # Creality K1 series
    if [ -d "/usr/data/printer_data" ]; then
        echo "/usr/data/printer_data"
        return 0
    fi
    # Standard installation
    if [ -d "$HOME/printer_data" ]; then
        echo "$HOME/printer_data"
        return 0
    fi
    return 1
}

# Detect install directory
detect_install_dir() {
    # Anycubic Kobra S1 (Rinkhals) - use /userdata which is writable
    if [ -d "/userdata" ]; then
        echo "/userdata/polar-cloud-klipper"
        return 0
    fi
    # Creality K1 series
    if [ -d "/usr/data" ]; then
        echo "/usr/data/polar-cloud-klipper"
        return 0
    fi
    # Standard installation
    echo "$HOME/polar-cloud-klipper"
}

# Check for required commands
check_requirements() {
    print_info "Checking requirements..."

    # Check for curl or wget
    if command -v curl >/dev/null 2>&1; then
        DOWNLOAD_CMD="curl -sSL"
        DOWNLOAD_OUT="-o"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOAD_CMD="wget -qO-"
        DOWNLOAD_OUT="-O"
    else
        print_error "Neither curl nor wget found. Cannot download files."
        exit 1
    fi

    # Check for Python 3
    if command -v python3 >/dev/null 2>&1; then
        PYTHON_CMD="python3"
    elif command -v python >/dev/null 2>&1; then
        # Check if it's Python 3
        if python --version 2>&1 | grep -q "Python 3"; then
            PYTHON_CMD="python"
        else
            print_error "Python 3 is required but not found."
            exit 1
        fi
    else
        print_error "Python 3 is required but not found."
        exit 1
    fi

    PYTHON_VERSION=$($PYTHON_CMD --version 2>&1)
    print_success "Found $PYTHON_VERSION"

    # Check for tar
    if ! command -v tar >/dev/null 2>&1; then
        print_error "tar is required but not found."
        exit 1
    fi
}

# Detect if running on Anycubic Kobra S1 (Rinkhals)
is_rinkhals() {
    [ -d "/userdata/app/gk/printer_data" ] && [ -f "/ac_lib/lib/third_bin/ffmpeg" ]
}

# Check Python dependencies
check_python_deps() {
    print_info "Checking Python dependencies..."

    INSTALL_DIR=$(detect_install_dir)
    LIB_DIR="$INSTALL_DIR/lib"

    # On Rinkhals, we must install to a persistent location
    # The default site-packages is on a tmpfs and gets wiped on reboot
    if is_rinkhals; then
        print_info "Detected Anycubic Kobra S1 (Rinkhals)"
        print_info "Installing packages to persistent location: $LIB_DIR"
        USE_TARGET_DIR=true
        mkdir -p "$LIB_DIR"
        export PYTHONPATH="$LIB_DIR:$PYTHONPATH"
    else
        USE_TARGET_DIR=false
    fi

    # Required modules
    MISSING_DEPS=""

    # Check requests
    if ! $PYTHON_CMD -c "import requests" 2>/dev/null; then
        MISSING_DEPS="$MISSING_DEPS requests"
    fi

    # Check socketio
    if ! $PYTHON_CMD -c "import socketio" 2>/dev/null; then
        MISSING_DEPS="$MISSING_DEPS python-socketio"
    fi

    # Check websocket-client (required for Socket.IO websocket transport)
    if ! $PYTHON_CMD -c "import websocket" 2>/dev/null; then
        MISSING_DEPS="$MISSING_DEPS websocket-client"
    fi

    # Check for RSA library (cryptography or rsa)
    # Note: cryptography requires Rust compilation which isn't available on Rinkhals
    # so we always use the pure-Python rsa package on embedded systems
    if ! $PYTHON_CMD -c "import cryptography" 2>/dev/null; then
        if ! $PYTHON_CMD -c "import rsa" 2>/dev/null; then
            MISSING_DEPS="$MISSING_DEPS rsa"
        else
            print_success "Found rsa package (pure-Python)"
        fi
    else
        print_success "Found cryptography package"
    fi

    if [ -n "$MISSING_DEPS" ]; then
        print_warning "Missing Python packages:$MISSING_DEPS"
        print_info "Attempting to install missing packages..."

        for pkg in $MISSING_DEPS; do
            print_info "Installing $pkg..."
            if [ "$USE_TARGET_DIR" = true ]; then
                # Install to persistent location for Rinkhals
                if $PYTHON_CMD -m pip install --target="$LIB_DIR" "$pkg" 2>/dev/null; then
                    print_success "Installed $pkg to $LIB_DIR"
                else
                    print_error "Failed to install $pkg"
                    print_error "Please install manually: $PYTHON_CMD -m pip install --target=$LIB_DIR $pkg"
                    exit 1
                fi
            else
                # Try system-wide install first (for root on embedded systems)
                # Use --break-system-packages for newer pip versions that require it
                if $PYTHON_CMD -m pip install "$pkg" --break-system-packages 2>/dev/null; then
                    print_success "Installed $pkg"
                elif $PYTHON_CMD -m pip install "$pkg" 2>/dev/null; then
                    print_success "Installed $pkg"
                elif $PYTHON_CMD -m pip install --user "$pkg" 2>/dev/null; then
                    print_success "Installed $pkg (user)"
                else
                    print_error "Failed to install $pkg"
                    print_error "Please install manually: $PYTHON_CMD -m pip install $pkg"
                    exit 1
                fi
            fi
        done

        # Verify all dependencies are now importable
        print_info "Verifying installed packages..."
        VERIFY_FAILED=""
        $PYTHON_CMD -c "import requests" 2>/dev/null || VERIFY_FAILED="$VERIFY_FAILED requests"
        $PYTHON_CMD -c "import socketio" 2>/dev/null || VERIFY_FAILED="$VERIFY_FAILED socketio"
        $PYTHON_CMD -c "import websocket" 2>/dev/null || VERIFY_FAILED="$VERIFY_FAILED websocket"

        if [ -n "$VERIFY_FAILED" ]; then
            print_error "Package verification failed for:$VERIFY_FAILED"
            print_error "Packages were installed but Python cannot import them."
            if [ "$USE_TARGET_DIR" = true ]; then
                print_info "PYTHONPATH is set to: $PYTHONPATH"
            fi
            print_info "This may be a PATH issue. Try running:"
            print_info "  $PYTHON_CMD -m pip show websocket-client"
            print_info "  $PYTHON_CMD -c \"import sys; print(sys.path)\""
            exit 1
        fi
        print_success "All packages verified"
    else
        print_success "All Python dependencies available"
    fi
}

# Download and install
install_polar_cloud() {
    INSTALL_DIR=$(detect_install_dir)
    PRINTER_DATA=$(detect_printer_data_path)

    if [ -z "$PRINTER_DATA" ]; then
        print_error "Could not detect printer_data path. Is Moonraker installed?"
        exit 1
    fi

    print_info "Install directory: $INSTALL_DIR"
    print_info "Printer data path: $PRINTER_DATA"

    # Create install directory
    mkdir -p "$INSTALL_DIR"

    # Download from main branch
    DOWNLOAD_URL="https://github.com/Polar3D/polar-cloud-klipper/archive/refs/heads/main.tar.gz"
    TARBALL="/tmp/polar-cloud-klipper.tar.gz"

    print_info "Downloading Polar Cloud Klipper..."
    rm -f "$TARBALL"

    # Use curl with --fail to detect HTTP errors, and follow redirects
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL -o "$TARBALL" "$DOWNLOAD_URL" 2>/dev/null; then
            print_success "Downloaded from GitHub"
        else
            print_error "Failed to download from GitHub"
            exit 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q -O "$TARBALL" "$DOWNLOAD_URL" 2>/dev/null; then
            print_success "Downloaded from GitHub"
        else
            print_error "Failed to download from GitHub"
            exit 1
        fi
    else
        print_error "Neither curl nor wget available"
        exit 1
    fi

    # Verify download is a valid gzip file
    if ! gzip -t "$TARBALL" 2>/dev/null; then
        print_error "Downloaded file is not a valid archive"
        cat "$TARBALL" | head -1
        exit 1
    fi

    print_info "Extracting files..."
    tar -xzf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1
    rm -f "$TARBALL"

    print_success "Files extracted to $INSTALL_DIR"

    # Create config directory if needed
    mkdir -p "$PRINTER_DATA/config"
    mkdir -p "$PRINTER_DATA/logs"

    # Create default config if not exists
    CONFIG_FILE="$PRINTER_DATA/config/polar_cloud.conf"
    if [ ! -f "$CONFIG_FILE" ]; then
        print_info "Creating default configuration..."
        cat > "$CONFIG_FILE" << 'EOF'
[polar_cloud]
server_url = https://printer4.polar3d.com
# username = your_email@example.com
# pin = your_pin
# serial_number will be set after registration
machine_type = Cartesian
manufacturer = ac
printer_type = Anycubic Kobra S1
max_image_size = 150000
webcam_enabled = true
verbose = false
status_interval = 60
EOF
        print_success "Created $CONFIG_FILE"
        print_warning "Please edit $CONFIG_FILE to add your Polar Cloud credentials"
    fi

    # Install service
    install_service "$INSTALL_DIR" "$PRINTER_DATA"
}

# Install Rinkhals app (for Anycubic Kobra S1 with Rinkhals firmware)
install_rinkhals_app() {
    INSTALL_DIR="$1"
    PRINTER_DATA="$2"

    print_info "Installing as Rinkhals app..."

    # Find the current Rinkhals version directory
    RINKHALS_CURRENT=$(readlink -f /useremain/rinkhals/.current 2>/dev/null)
    if [ -z "$RINKHALS_CURRENT" ]; then
        RINKHALS_CURRENT=$(ls -d /useremain/rinkhals/20* 2>/dev/null | tail -1)
    fi

    if [ -z "$RINKHALS_CURRENT" ]; then
        print_error "Could not find Rinkhals installation directory"
        return 1
    fi

    RINKHALS_APPS="$RINKHALS_CURRENT/home/rinkhals/apps"
    APP_DIR="$RINKHALS_APPS/60-polar-cloud"

    print_info "Rinkhals apps directory: $RINKHALS_APPS"

    # Create the app directory
    mkdir -p "$APP_DIR"

    # Create app.json
    cat > "$APP_DIR/app.json" << 'EOF'
{
    "$version": "1",
    "name": "Polar Cloud",
    "description": "Connect your printer to Polar Cloud for remote monitoring and control.",
    "version": "1.0.0"
}
EOF
    print_success "Created app.json"

    # Create app.sh
    cat > "$APP_DIR/app.sh" << EOF
. /useremain/rinkhals/.current/tools.sh

APP_ROOT=\$(dirname \$(realpath \$0))
POLAR_DIR="$INSTALL_DIR"
PIDFILE="/var/run/polar_cloud.pid"
LOGFILE="$PRINTER_DATA/logs/polar_cloud.log"

export PYTHONPATH="\$POLAR_DIR/lib:\$PYTHONPATH"
export LD_LIBRARY_PATH="/ac_lib/lib/third_lib:\$LD_LIBRARY_PATH"

status() {
    if [ -f "\$PIDFILE" ]; then
        PID=\$(cat "\$PIDFILE")
        if kill -0 "\$PID" 2>/dev/null; then
            report_status \$APP_STATUS_STARTED "\$PID"
            return
        fi
        rm -f "\$PIDFILE"
    fi
    report_status \$APP_STATUS_STOPPED
}

start() {
    # Check if already running
    if [ -f "\$PIDFILE" ]; then
        PID=\$(cat "\$PIDFILE")
        if kill -0 "\$PID" 2>/dev/null; then
            log "Polar Cloud already running (PID: \$PID)"
            return 0
        fi
        rm -f "\$PIDFILE"
    fi

    log "Starting Polar Cloud..."

    if [ ! -d "\$POLAR_DIR" ]; then
        log "Polar Cloud not installed at \$POLAR_DIR"
        return 1
    fi

    cd "\$POLAR_DIR"
    nohup python3 "\$POLAR_DIR/src/polar_cloud.py" >> "\$LOGFILE" 2>&1 &
    PID=\$!
    echo \$PID > "\$PIDFILE"
    log "Polar Cloud started (PID: \$PID)"
}

stop() {
    log "Stopping Polar Cloud..."
    if [ -f "\$PIDFILE" ]; then
        PID=\$(cat "\$PIDFILE")
        kill "\$PID" 2>/dev/null
        rm -f "\$PIDFILE"
    fi
    log "Polar Cloud stopped"
}

case "\$1" in
    status) status ;;
    start)  start ;;
    stop)   stop ;;
    *)      echo "Usage: \$0 {status|start|stop}" ;;
esac
EOF
    chmod +x "$APP_DIR/app.sh"
    print_success "Created app.sh"

    # Enable the app
    touch "$APP_DIR/.enabled"
    print_success "Enabled Polar Cloud app"

    # Also create a convenience script in the install directory
    SERVICE_SCRIPT="$INSTALL_DIR/polar_cloud_service.sh"
    cat > "$SERVICE_SCRIPT" << EOF
#!/bin/sh
# Convenience wrapper for Rinkhals app
$APP_DIR/app.sh \$1
EOF
    chmod +x "$SERVICE_SCRIPT"

    print_info "Starting Polar Cloud via Rinkhals app..."
    "$APP_DIR/app.sh" start
}

# Install service for non-Rinkhals systems (Creality K1, etc.)
install_init_service() {
    INSTALL_DIR="$1"
    PRINTER_DATA="$2"

    print_info "Installing init.d service..."

    # Create service script
    SERVICE_SCRIPT="$INSTALL_DIR/polar_cloud_service.sh"
    cat > "$SERVICE_SCRIPT" << EOF
#!/bin/sh
# Polar Cloud Service Script for Embedded Systems

POLAR_DIR="$INSTALL_DIR"
PIDFILE="/var/run/polar_cloud.pid"
LOGFILE="$PRINTER_DATA/logs/polar_cloud.log"
PYTHON_CMD="$PYTHON_CMD"

start() {
    if [ -f "\$PIDFILE" ] && kill -0 \$(cat "\$PIDFILE") 2>/dev/null; then
        echo "Polar Cloud is already running"
        return 1
    fi
    echo "Starting Polar Cloud..."
    cd "\$POLAR_DIR"
    nohup \$PYTHON_CMD "\$POLAR_DIR/src/polar_cloud.py" >> "\$LOGFILE" 2>&1 &
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
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac
EOF
    chmod +x "$SERVICE_SCRIPT"
    print_success "Created service script: $SERVICE_SCRIPT"

    # Try to install init script if /etc/init.d exists and is writable
    if [ -d "/etc/init.d" ] && [ -w "/etc/init.d" ]; then
        INIT_SCRIPT="/etc/init.d/S99polar_cloud"
        cat > "$INIT_SCRIPT" << EOF
#!/bin/sh
# Polar Cloud startup script
$SERVICE_SCRIPT \$1
EOF
        chmod +x "$INIT_SCRIPT"
        print_success "Created init script: $INIT_SCRIPT"
    else
        print_warning "Could not create init script - service won't auto-start on boot"
        print_info "You may need to add $SERVICE_SCRIPT to your startup scripts manually"
    fi

    print_info "Starting Polar Cloud service..."
    "$SERVICE_SCRIPT" start
}

# Install service (platform-specific)
install_service() {
    INSTALL_DIR="$1"
    PRINTER_DATA="$2"

    print_info "Installing service..."

    if is_rinkhals; then
        # Rinkhals uses its own app framework for startup
        install_rinkhals_app "$INSTALL_DIR" "$PRINTER_DATA"
    else
        # Other embedded systems use init.d
        install_init_service "$INSTALL_DIR" "$PRINTER_DATA"
    fi
}

# Main installation flow
main() {
    echo ""
    echo "=========================================="
    echo "  Polar Cloud Klipper - Embedded Installer"
    echo "=========================================="
    echo ""

    check_requirements
    check_python_deps
    install_polar_cloud

    echo ""
    print_success "Installation complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Edit your configuration:"
    echo "     vi $(detect_printer_data_path)/config/polar_cloud.conf"
    echo ""
    echo "  2. Add your Polar Cloud username and PIN"
    echo ""
    echo "  3. Restart the service:"
    echo "     $(detect_install_dir)/polar_cloud_service.sh restart"
    echo ""
    echo "  4. Check the logs:"
    echo "     tail -f $(detect_printer_data_path)/logs/polar_cloud.log"
    echo ""
}

main
