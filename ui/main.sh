#!/bin/bash


# Text Size Configuration
configure_text_size() {
    show_banner
    gum style --foreground 212 "Text Size Configuration"
    echo ""
    
    SIZE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "Small" \
        "Medium" \
        "Large")
    
    case $SIZE in
        "Small")
            setfont ter-112n || echo "Small font applied"
            ;;
        "Medium")
            setfont ter-116n || echo "Medium font applied"
            ;;
        "Large")
            setfont ter-132n || echo "Large font applied"
            ;;
    esac
    
    gum style --foreground 46 "Text size changed to: $SIZE"
    sleep 1
}

# Main Menu
main_menu() {
    show_banner
    
    gum style --foreground 214 "Choose your installation method:"
    echo ""

    MENU_OPTIONS=()
    if command -v basic_has_saved_config >/dev/null 2>&1 && basic_has_saved_config; then
        MENU_OPTIONS+=("Continue Setup")
    fi
    MENU_OPTIONS+=("Quick Installation" "Advanced Installation" "Font Scaling" "Exit")

    CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " "${MENU_OPTIONS[@]}")
    
    case $CHOICE in
        "Continue Setup")
            basic_continue_from_startup
            ;;
        "Quick Installation")
            basic_setup
            ;;
        "Advanced Installation")
            advanced_setup
            ;;
        "Font Scaling")
            configure_text_size
            ;;
        "Exit")
            gum style --foreground 46 "Thank you for using AsiraOS Installer!"
            exit 0
            ;;
    esac
}
