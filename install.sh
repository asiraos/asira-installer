#!/bin/bash
# AsiraOS - The Future of Linux
# Copyright (c) 2024 AsiraOS Team
# https://asiraos.github.io
# Licensed under GPL-3.0


# AsiraOS Installer - Main Script
set -e
sudo pacman -Sy --noconfirm archlinux-keyring >/dev/null 2>&1

# Counter for quit attempts
QUIT_ATTEMPTS=0

# Handle Ctrl+C - show message and increment counter
handle_interrupt() {
    QUIT_ATTEMPTS=$((QUIT_ATTEMPTS + 1))
    if [ $QUIT_ATTEMPTS -ge 4 ]; then
        echo -e "\n${RED}Exiting installer...${NC}"
        exit 0
    else
        echo -e "\n${YELLOW}Press Ctrl+C $((4 - QUIT_ATTEMPTS)) more times to quit${NC}"
    fi
}

trap 'handle_interrupt' INT

# Prevent other signals
trap '' TERM QUIT TSTP

# Source all modules
source ./lib/colors.sh
source ./lib/ui.sh
source ./lib/banner.sh
source ./ui/network.sh
source ./ui/user.sh
source ./ui/disk.sh
source ./ui/system.sh
source ./ui/packages.sh
source ./ui/drivers.sh
source ./ui/main.sh
source ./ui/basic.sh
source ./ui/advanced.sh

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This installer must be run as root.${NC}"
    echo -e "${YELLOW}Please run: sudo ./install.sh${NC}"
    exit 1
fi

# Create temp directory for installer data
mkdir -p /tmp/asiraos
chmod 755 /tmp/asiraos

# Check if gum is installed
if ! type -P gum &> /dev/null; then
    echo -e "${RED}Error: gum is required but not installed.${NC}"
    echo "Please install gum first: https://github.com/charmbracelet/gum"
    exit 1
fi

# Enable centered UI defaults for gum commands.
ui_setup_centered_gum

# Start the installer in a loop
while true; do
    main_menu || continue
done
