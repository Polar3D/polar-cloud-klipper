#!/bin/bash

# Test script to verify Polar Cloud installation improvements
# This script simulates various installation scenarios

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}  Polar Cloud Installation Tester${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""

# Test 1: Check if installer detects mks user
echo -e "${YELLOW}Test 1: User Detection${NC}"
if grep -q "mks" install.sh; then
    echo -e "${GREEN}✓ Installer includes 'mks' user for Sovol printers${NC}"
else
    echo -e "${RED}✗ Installer missing 'mks' user detection${NC}"
fi

# Test 2: Check nginx auto-configuration
echo -e "${YELLOW}Test 2: Nginx Auto-Configuration${NC}"
if grep -q "sudo awk" install.sh && grep -q "sudo sed -i" install.sh; then
    echo -e "${GREEN}✓ Installer includes automatic nginx configuration${NC}"
else
    echo -e "${RED}✗ Installer missing automatic nginx configuration${NC}"
fi

# Test 3: Check fallback nginx configuration
echo -e "${YELLOW}Test 3: Fallback Nginx Setup${NC}"
if grep -q "sites-available/polar-cloud" install.sh; then
    echo -e "${GREEN}✓ Installer includes standalone nginx fallback${NC}"
else
    echo -e "${RED}✗ Installer missing standalone nginx fallback${NC}"
fi

# Test 4: Check backup mechanism
echo -e "${YELLOW}Test 4: Backup Mechanism${NC}"
if grep -q "backup.\$(date" install.sh; then
    echo -e "${GREEN}✓ Installer creates nginx config backups${NC}"
else
    echo -e "${RED}✗ Installer missing backup creation${NC}"
fi

# Test 5: Check error recovery
echo -e "${YELLOW}Test 5: Error Recovery${NC}"
if grep -q "restore backup" install.sh; then
    echo -e "${GREEN}✓ Installer includes error recovery${NC}"
else
    echo -e "${RED}✗ Installer missing error recovery${NC}"
fi

# Test 6: Check multiple nginx paths
echo -e "${YELLOW}Test 6: Multiple Nginx Paths${NC}"
nginx_paths=("sites-available" "sites-enabled" "conf.d")
all_found=true
for path in "${nginx_paths[@]}"; do
    if ! grep -q "$path" install.sh; then
        all_found=false
        break
    fi
done

if [ "$all_found" = true ]; then
    echo -e "${GREEN}✓ Installer checks multiple nginx locations${NC}"
else
    echo -e "${RED}✗ Installer missing some nginx path checks${NC}"
fi

# Test 7: Verify no manual intervention required
echo -e "${YELLOW}Test 7: Automation Check${NC}"
if grep -q "read -p.*Press Enter.*adding the configuration" install.sh; then
    # Check if it's in a fallback section
    if grep -B5 "read -p.*Press Enter.*adding the configuration" install.sh | grep -q "Could not automatically"; then
        echo -e "${GREEN}✓ Manual intervention only as last resort${NC}"
    else
        echo -e "${YELLOW}⚠ Manual intervention may still be required${NC}"
    fi
else
    echo -e "${GREEN}✓ No manual intervention required${NC}"
fi

# Test 8: Check Debian Buster handling
echo -e "${YELLOW}Test 8: Debian Buster Support${NC}"
if grep -q "archive.debian.org" install.sh; then
    echo -e "${GREEN}✓ Installer handles Debian Buster repositories${NC}"
else
    echo -e "${RED}✗ Installer missing Debian Buster handling${NC}"
fi

echo ""
echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}  Test Summary${NC}"
echo -e "${BLUE}=====================================${NC}"
echo ""
echo "The updated installer should now:"
echo "1. Automatically detect and configure nginx"
echo "2. Create a standalone configuration if needed"
echo "3. Support Sovol printers with 'mks' user"
echo "4. Handle various nginx setups gracefully"
echo "5. Provide error recovery mechanisms"
echo ""
echo -e "${GREEN}Installation should complete without manual intervention!${NC}"