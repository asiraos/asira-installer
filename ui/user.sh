#!/bin/bash


# User Creation
user_creation() {
    show_banner
    gum style --foreground 214 "User Creation"
    echo ""
    
    USERNAME=$(gum input --placeholder "Enter username")
    if [ -z "$USERNAME" ]; then
        gum style --foreground 196 "Username cannot be empty"
        gum input --placeholder "Press Enter to try again..."
        user_creation
        return
    fi
    
    PASSWORD=$(gum input --password --placeholder "Enter password")
    if [ -z "$PASSWORD" ]; then
        gum style --foreground 196 "Password cannot be empty"
        gum input --placeholder "Press Enter to try again..."
        user_creation
        return
    fi
    
    CONFIRM_PASSWORD=$(gum input --password --placeholder "Confirm password")
    if [ "$PASSWORD" != "$CONFIRM_PASSWORD" ]; then
        gum style --foreground 196 "Passwords do not match"
        gum input --placeholder "Press Enter to try again..."
        user_creation
        return
    fi
    
    gum style --foreground 46 "User created: $USERNAME"
    mkdir -p /tmp/asiraos
    echo "$USERNAME" > /tmp/asiraos/username
    echo "$PASSWORD" > /tmp/asiraos/password
    sleep 1
    
    # Handle basic mode progression
    if [ "$BASIC_MODE" = true ]; then
        source ./ui/basic.sh
        basic_step_9_hostname
    else
        disk_selection
    fi
}
