#!/bin/bash


# Advanced Setup Menu
advanced_setup() {
    show_banner
    gum style --foreground 196 "ADVANCED SETUP"
    echo ""
    
    # Show preview of selections
    gum style --foreground 212 "Current Configuration:"
    echo ""
    
    # Network status
    if ping -c 1 8.8.8.8 &> /dev/null; then
        gum style --foreground 46 "✓ Network: Connected"
    else
        gum style --foreground 196 "✗ Network: Not connected"
    fi
    
    # Disk mountpoints
    if [ -f "/tmp/asiraos/mounts" ]; then
        gum style --foreground 46 "✓ Disk: Configured"
    else
        gum style --foreground 196 "✗ Disk: Not configured"
    fi
    
    # Locale
    if [ -f "/tmp/asiraos/locale" ]; then
        gum style --foreground 46 "✓ Locale: $(cat /tmp/asiraos/locale)"
    else
        gum style --foreground 196 "✗ Locale: Not selected"
    fi
    
    # Swap
    if [ -f "/tmp/asiraos/swap" ]; then
        gum style --foreground 46 "✓ Swap: $(cat /tmp/asiraos/swap)"
    else
        gum style --foreground 196 "✗ Swap: Not configured"
    fi
    
    # Bootloader
    if [ -f "/tmp/asiraos/bootloader" ]; then
        gum style --foreground 46 "✓ Bootloader: $(cat /tmp/asiraos/bootloader)"
    else
        gum style --foreground 196 "✗ Bootloader: Not selected"
    fi
    
    # Kernel
    if [ -f "/tmp/asiraos/kernel" ]; then
        gum style --foreground 46 "✓ Kernel: $(cat /tmp/asiraos/kernel)"
    else
        gum style --foreground 196 "✗ Kernel: Not selected"
    fi
    
    # User info
    if [ -n "$USERNAME" ]; then
        gum style --foreground 46 "✓ User: $USERNAME"
    else
        gum style --foreground 196 "✗ User: Not configured"
    fi
    
    # Hostname
    if [ -f "/tmp/asiraos/hostname" ]; then
        gum style --foreground 46 "✓ Hostname: $(cat /tmp/asiraos/hostname)"
    else
        gum style --foreground 196 "✗ Hostname: Not set"
    fi
    
    # Desktop Environment
    if [ -f "/tmp/asiraos/desktop" ]; then
        gum style --foreground 46 "✓ Desktop: $(cat /tmp/asiraos/desktop)"
    else
        gum style --foreground 196 "✗ Desktop: Not selected"
    fi
    
    # Mirror
    if [ -f "/tmp/asiraos/mirror" ]; then
        MIRROR_NAME=$(basename "$(cat /tmp/asiraos/mirror)" | cut -d'/' -f3)
        gum style --foreground 46 "✓ Mirror: $MIRROR_NAME"
    else
        gum style --foreground 196 "✗ Mirror: Not selected"
    fi
    
    # Packages
    if [ -f "/tmp/asiraos/packages" ]; then
        PACKAGE_COUNT=$(sort /tmp/asiraos/packages | uniq | wc -l)
        gum style --foreground 46 "✓ Packages: $PACKAGE_COUNT selected"
    else
        gum style --foreground 196 "✗ Packages: None selected"
    fi
    
    # Drivers
    if [ -f "/tmp/asiraos/drivers" ]; then
        DRIVER_COUNT=$(grep -v "Skip Driver Selection" /tmp/asiraos/drivers | wc -l)
        if [ "$DRIVER_COUNT" -gt 0 ]; then
            gum style --foreground 46 "✓ Drivers: $DRIVER_COUNT selected"
        else
            gum style --foreground 196 "✗ Drivers: Skipped"
        fi
    else
        gum style --foreground 196 "✗ Drivers: Not selected"
    fi
    
    # Timezone
    if [ -f "/tmp/asiraos/timezone" ]; then
        gum style --foreground 46 "✓ Timezone: $(cat /tmp/asiraos/timezone)"
    else
        gum style --foreground 196 "✗ Timezone: Not selected"
    fi
    
    echo ""
    
    CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "Disk Selection" \
        "Locale Selection" \
        "Mirror Selection" \
        "Swap Configuration" \
        "Bootloader Selection" \
        "Kernel Selection" \
        "User Creation" \
        "Hostname Selection" \
        "Desktop Environment" \
        "Driver Selection" \
        "Network Detection" \
        "Package Selection" \
        "Timezone Selection" \
        "Install System" \
        "Back to Main Menu")
    
    case $CHOICE in
        "Disk Selection")
            disk_selection
            ;;
        "Locale Selection")
            locale_selection
            ;;
        "Mirror Selection")
            mirror_selection
            ;;
        "Swap Configuration")
            swap_config
            ;;
        "Bootloader Selection")
            bootloader_selection
            ;;
        "Kernel Selection")
            kernel_selection
            ;;
        "User Creation")
            user_creation
            ;;
        "Hostname Selection")
            hostname_selection
            ;;
        "Desktop Environment")
            desktop_selection
            ;;
        "Driver Selection")
            driver_selection
            ;;
        "Network Detection")
            network_detection
            ;;
        "Package Selection")
            package_selection
            ;;
        "Timezone Selection")
            timezone_selection
            ;;
        "Install System")
            install_system
            ;;
        "Back to Main Menu")
            main_menu
            ;;
    esac
}
