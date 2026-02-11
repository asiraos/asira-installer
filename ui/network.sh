#!/bin/bash


# Network Detection
network_detection() {
    show_banner
    gum style --foreground 214 "Network Detection"
    echo ""
    
    if ping -c 1 8.8.8.8 &> /dev/null; then
        gum style --foreground 46 "Network connection detected"
        sleep 1
        if [ "$BASIC_MODE" = true ]; then
            basic_step_14_disk
        else
            user_creation
        fi
    else
        gum style --foreground 196 "No network connection found"
        gum style --foreground 214 "Opening network configuration..."
        sleep 1
        nmtui
        if ping -c 1 8.8.8.8 &> /dev/null; then
            gum style --foreground 46 "Network configured successfully"
            sleep 1
            if [ "$BASIC_MODE" = true ]; then
                basic_step_14_disk
            else
                user_creation
            fi
        else
            gum style --foreground 196 "Network still not available"
            
            CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
                "Try Again" \
                "← Back")
            
            case $CHOICE in
                "Try Again")
                    network_detection
                    ;;
                "← Back")
                    if [ "$BASIC_MODE" = true ]; then
                        basic_step_12_kernel
                    else
                        main_menu
                    fi
                    ;;
            esac
        fi
    fi
    curl -sSL https://asiraos.github.io/core/asiraos-core.pubkey.asc | sudo pacman-key --add -
    sudo pacman -Sy
}
