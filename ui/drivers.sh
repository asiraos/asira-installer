#!/bin/bash

# Driver Selection Menu
driver_selection() {
    show_banner
    gum style --foreground 212 "Driver Selection"
    echo ""
    
    gum style --foreground 226 "Select graphics drivers to install:"
    echo ""
    
    DRIVERS=$(gum choose --no-limit --cursor-prefix "> " --selected-prefix "✓ " \
        "Nouveau Drivers (Open Source NVIDIA)" \
        "NVIDIA Proprietary" \
        "All Open Source" \
        "Intel Open Source" \
        "AMD Drivers" \
        "VirtualBox Guest Additions" \
        "Skip Driver Selection")
    
    # Save selected drivers
    echo "$DRIVERS" > /tmp/asiraos/drivers
    
    if [[ "$DRIVERS" == *"Skip Driver Selection"* ]]; then
        gum style --foreground 46 "✓ Skipping driver installation"
    else
        gum style --foreground 46 "✓ Selected drivers saved"
        echo ""
        echo "Selected drivers:"
        echo "$DRIVERS" | while read -r driver; do
            if [ -n "$driver" ]; then
                gum style --foreground 46 "  • $driver"
            fi
        done
    fi
    
    sleep 2
    
    # Continue to next step based on mode
    if [ "$BASIC_MODE" = true ]; then
        basic_step_12_packages
    else
        advanced_menu
    fi
}

# Get driver packages for pacstrap
get_driver_packages() {
    local packages=""
    
    if [ -f /tmp/asiraos/drivers ]; then
        while IFS= read -r driver; do
            case "$driver" in
                "Nouveau Drivers (Open Source NVIDIA)")
                    packages="$packages xf86-video-nouveau mesa"
                    ;;
                "NVIDIA Proprietary")
                    packages="$packages nvidia nvidia-utils nvidia-settings"
                    ;;
                "All Open Source")
                    packages="$packages xf86-video-nouveau xf86-video-amdgpu xf86-video-intel mesa"
                    ;;
                "Intel Open Source")
                    packages="$packages xf86-video-intel mesa"
                    ;;
                "AMD Drivers")
                    packages="$packages xf86-video-amdgpu mesa vulkan-radeon"
                    ;;
                "VirtualBox Guest Additions")
                    packages="$packages virtualbox-guest-utils virtualbox-guest-modules-arch"
                    ;;
            esac
        done < /tmp/asiraos/drivers
    fi
    
    echo "$packages"
}
