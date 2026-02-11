#!/bin/bash


# Package Selection
package_selection() {
    show_banner
    gum style --foreground 212 "Package Selection"
    echo ""
    
    # Show currently selected packages (unique only)
    if [ -f "/tmp/asiraos/packages" ]; then
        gum style --foreground 212 "Selected packages:"
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && gum style --foreground 46 "$pkg"
        done < <(sort /tmp/asiraos/packages | uniq)
        echo ""
        echo ""
    fi
    
    CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "Search and Add Package" \
        "Clear All Packages" \
        "🚀 Continue to Next Step" \
        "← Back")
    
    case $CHOICE in
        "Search and Add Package")
            search_and_add_package
            ;;
        "Clear All Packages")
            rm -f /tmp/asiraos/packages
            gum style --foreground 205 "All packages cleared"
            sleep 1
            package_selection
            ;;
        "🚀 Continue to Next Step")
            if [ "$BASIC_MODE" = true ]; then
                basic_step_8_user
            else
                advanced_setup
            fi
            ;;
        "← Back")
            if [ "$BASIC_MODE" = true ]; then
                basic_step_7_packages
            else
                advanced_setup
            fi
            ;;
    esac
}

# Search and Add Package
search_and_add_package() {
    show_banner
    gum style --foreground 205 "Search Packages"
    echo ""
    
    # Get all packages and use gum filter for live search
    SELECTED_PACKAGE=$(pacman -Slq | gum filter --placeholder="Type to search packages..." || true)
    
    if [ -n "$SELECTED_PACKAGE" ] && [ "$SELECTED_PACKAGE" != "" ]; then
        # Add to selected packages (avoid duplicates)
        if ! grep -q "^$SELECTED_PACKAGE$" /tmp/asiraos/packages 2>/dev/null; then
            echo "$SELECTED_PACKAGE" >> /tmp/asiraos/packages
            gum style --foreground 46 "Added: $SELECTED_PACKAGE"
            sleep 1
        else
            gum style --foreground 205 "Package already selected: $SELECTED_PACKAGE"
            sleep 1
        fi
    fi
    
    # Return to main package menu
    package_selection
}
