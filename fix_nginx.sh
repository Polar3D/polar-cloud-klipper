#!/bin/bash

# Quick script to add nginx configuration for existing Polar Cloud installation

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Adding Polar Cloud nginx configuration...${NC}"

# Find the user's home directory
USER="mks"
HOME_DIR="/home/mks"
POLAR_DIR="$HOME_DIR/polar-cloud"

# Find nginx config
NGINX_CONF="/etc/nginx/sites-available/mainsail"

if [ ! -f "$NGINX_CONF" ]; then
    echo -e "${YELLOW}Mainsail nginx config not found at expected location${NC}"
    exit 1
fi

# Check if already configured
if grep -q "location.*polar-cloud" "$NGINX_CONF"; then
    echo -e "${GREEN}✓ Nginx already configured for Polar Cloud${NC}"
    exit 0
fi

# Create the nginx snippet
NGINX_SNIPPET="
# Polar Cloud nginx configuration snippet
# Added by fix_nginx.sh

# Redirect /polar-cloud to /polar-cloud/ for user-friendliness
location = /polar-cloud {
    return 301 \$scheme://\$host/polar-cloud/;
}

location /polar-cloud/ {
    alias $POLAR_DIR/web/;
    try_files \$uri \$uri/ /polar-cloud/index.html;
}"

# Backup the config
sudo cp "$NGINX_CONF" "${NGINX_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
echo -e "${BLUE}Created backup of nginx configuration${NC}"

# Add the configuration (insert before the last closing brace)
TEMP_FILE="/tmp/nginx_fix.$$"
LAST_BRACE=$(grep -n '^}$' "$NGINX_CONF" | tail -1 | cut -d: -f1)

if [ -n "$LAST_BRACE" ]; then
    head -n $((LAST_BRACE - 1)) "$NGINX_CONF" | sudo tee "$TEMP_FILE" > /dev/null
    echo "$NGINX_SNIPPET" | sudo tee -a "$TEMP_FILE" > /dev/null
    tail -n +$LAST_BRACE "$NGINX_CONF" | sudo tee -a "$TEMP_FILE" > /dev/null
    
    sudo mv "$TEMP_FILE" "$NGINX_CONF"
    
    # Test and reload nginx
    if sudo nginx -t; then
        sudo systemctl reload nginx
        echo -e "${GREEN}✓ Nginx configuration added and reloaded successfully!${NC}"
        echo ""
        echo "You can now access Polar Cloud at: http://your-printer-ip/polar-cloud/"
    else
        echo "Nginx test failed, restoring backup..."
        sudo cp "${NGINX_CONF}.backup."* "$NGINX_CONF"
        sudo nginx -t
        sudo systemctl reload nginx
    fi
else
    echo "Could not find location to insert configuration"
    echo "Please manually add this before the final '}' in $NGINX_CONF:"
    echo "$NGINX_SNIPPET"
fi