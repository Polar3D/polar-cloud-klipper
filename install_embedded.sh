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

# Check Python dependencies
check_python_deps() {
    print_info "Checking Python dependencies..."

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

    # Check for RSA library (cryptography or rsa)
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
            if $PYTHON_CMD -m pip install --user "$pkg" 2>/dev/null; then
                print_success "Installed $pkg"
            else
                print_error "Failed to install $pkg"
                print_error "Please install manually: $PYTHON_CMD -m pip install $pkg"
                exit 1
            fi
        done
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

    # Download release tarball
    RELEASE_URL="https://github.com/Polar3D/polar-cloud-klipper/releases/latest/download/polar-cloud-klipper.tar.gz"
    TARBALL="/tmp/polar-cloud-klipper.tar.gz"

    print_info "Downloading Polar Cloud Klipper..."
    if [ "$DOWNLOAD_CMD" = "curl -sSL" ]; then
        curl -sSL -o "$TARBALL" "$RELEASE_URL" || {
            # Fallback to downloading from main branch
            print_warning "Release tarball not found, downloading from main branch..."
            curl -sSL -o "$TARBALL" "https://github.com/Polar3D/polar-cloud-klipper/archive/refs/heads/main.tar.gz"
        }
    else
        wget -qO "$TARBALL" "$RELEASE_URL" || {
            print_warning "Release tarball not found, downloading from main branch..."
            wget -qO "$TARBALL" "https://github.com/Polar3D/polar-cloud-klipper/archive/refs/heads/main.tar.gz"
        }
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

# Install service (BusyBox-compatible)
install_service() {
    INSTALL_DIR="$1"
    PRINTER_DATA="$2"

    print_info "Installing service..."

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

    # Try to install init script if possible
    if [ -d "/etc/init.d" ]; then
        INIT_SCRIPT="/etc/init.d/S99polar_cloud"
        cat > "$INIT_SCRIPT" << EOF
#!/bin/sh
# Polar Cloud startup script
$SERVICE_SCRIPT \$1
EOF
        chmod +x "$INIT_SCRIPT"
        print_success "Created init script: $INIT_SCRIPT"
    fi

    print_info "Starting Polar Cloud service..."
    "$SERVICE_SCRIPT" start
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
