#!/bin/bash

# Basic Setup Menu - Automatic step-by-step configuration
basic_setup() {
    BASIC_MODE=true
    basic_start_menu
}

basic_has_saved_config() {
    [ -n "${USERNAME:-}" ] || [ -n "${PASSWORD:-}" ] || \
    [ -f "/tmp/asiraos/keymap" ] || [ -f "/tmp/asiraos/locale" ] || \
    [ -f "/tmp/asiraos/timezone" ] || [ -f "/tmp/asiraos/mirror" ] || \
    [ -f "/tmp/asiraos/desktop" ] || [ -f "/tmp/asiraos/drivers" ] || \
    [ -f "/tmp/asiraos/packages" ] || [ -f "/tmp/asiraos/hostname" ] || \
    [ -f "/tmp/asiraos/swap" ] || [ -f "/tmp/asiraos/bootloader" ] || \
    [ -f "/tmp/asiraos/kernel" ] || [ -f "/tmp/asiraos/mounts" ]
}

basic_reset_config() {
    rm -f /tmp/asiraos/keymap \
          /tmp/asiraos/locale \
          /tmp/asiraos/timezone \
          /tmp/asiraos/mirror \
          /tmp/asiraos/mirror_country \
          /tmp/asiraos/desktop \
          /tmp/asiraos/drivers \
          /tmp/asiraos/packages \
          /tmp/asiraos/hostname \
          /tmp/asiraos/swap \
          /tmp/asiraos/bootloader \
          /tmp/asiraos/kernel \
          /tmp/asiraos/mounts
    USERNAME=""
    PASSWORD=""
    BASIC_RESUME_MODE=false
}

basic_has_required_mounts() {
    [ -f /tmp/asiraos/mounts ] || return 1
    grep -q " -> /$" /tmp/asiraos/mounts || return 1
    grep -q " -> /boot/efi$" /tmp/asiraos/mounts || grep -q " -> /boot$" /tmp/asiraos/mounts || return 1
    return 0
}

basic_selected_disk_label() {
    local root_part root_disk
    root_part=$(grep " -> /$" /tmp/asiraos/mounts 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$root_part" ] && [ -b "$root_part" ]; then
        root_disk=$(lsblk -no PKNAME "$root_part" 2>/dev/null | head -1)
        if [ -n "$root_disk" ]; then
            echo "/dev/$root_disk"
            return
        fi
        echo "$root_part"
        return
    fi
    echo "Not set"
}

basic_next_incomplete_step() {
    local keymap locale
    keymap=$(cat /tmp/asiraos/keymap 2>/dev/null || true)
    locale=$(cat /tmp/asiraos/locale 2>/dev/null || true)

    if [ -z "$keymap" ] || [ -z "$locale" ]; then
        echo "basic_step_1_keyboard"; return
    fi
    [ -f /tmp/asiraos/timezone ] || { echo "basic_step_3_timezone"; return; }
    [ -f /tmp/asiraos/mirror ] || { echo "basic_step_4_mirror"; return; }
    [ -f /tmp/asiraos/desktop ] || { echo "basic_step_5_desktop"; return; }
    [ -f /tmp/asiraos/drivers ] || { echo "basic_step_6_drivers"; return; }
    [ -n "${USERNAME:-}" ] && [ -n "${PASSWORD:-}" ] || { echo "basic_step_8_user"; return; }
    [ -f /tmp/asiraos/hostname ] || { echo "basic_step_9_hostname"; return; }
    [ -f /tmp/asiraos/swap ] || { echo "basic_step_10_swap"; return; }
    [ -f /tmp/asiraos/bootloader ] || { echo "basic_step_11_bootloader"; return; }
    [ -f /tmp/asiraos/kernel ] || { echo "basic_step_12_kernel"; return; }

    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        echo "basic_step_13_network"; return
    fi
    basic_has_required_mounts || { echo "basic_step_14_disk"; return; }
    echo "basic_step_15_install"
}

basic_start_menu() {
    local choice next_step
    show_banner
    gum style --foreground 212 "Basic Setup"

    if basic_has_saved_config; then
        basic_show_status_box
        choice=$(gum choose \
            "Continue with existing config" \
            "Start new basic setup" \
            "← Back")

        case "$choice" in
            "Continue with existing config")
                BASIC_RESUME_MODE=true
                next_step=$(basic_next_incomplete_step)
                "$next_step"
                ;;
            "Start new basic setup")
                basic_reset_config
                basic_step_1_keyboard
                ;;
            "← Back")
                main_menu
                ;;
        esac
    else
        choice=$(gum choose "Start basic setup" "← Back")
        case "$choice" in
            "Start basic setup")
                basic_step_1_keyboard
                ;;
            "← Back")
                main_menu
                ;;
        esac
    fi
}

basic_mask_password() {
    local pwd="${PASSWORD:-}"
    if [ -z "$pwd" ]; then
        echo "Not set"
    else
        printf '%*s' "${#pwd}" '' | tr ' ' '*'
    fi
}

basic_keymap_label() {
    local keymap="$1"
    case "$keymap" in
        us) echo "English (US)" ;;
        uk) echo "English (UK)" ;;
        de) echo "German (DE)" ;;
        fr) echo "French (FR)" ;;
        es) echo "Spanish (ES)" ;;
        it) echo "Italian (IT)" ;;
        ru) echo "Russian (RU)" ;;
        jp106) echo "Japanese (JP)" ;;
        br-abnt2) echo "Portuguese (BR)" ;;
        *) echo "${keymap:-Not set}" ;;
    esac
}

basic_show_status_box() {
    local keymap keymap_label user_val pass_val hostname_val disk_val table_output term_width clean_line left
    keymap=$(cat /tmp/asiraos/keymap 2>/dev/null || true)
    keymap_label=$(basic_keymap_label "$keymap")
    user_val="${USERNAME:-Not set}"
    pass_val=$(basic_mask_password)
    hostname_val=$(cat /tmp/asiraos/hostname 2>/dev/null || echo "Not set")
    disk_val=$(basic_selected_disk_label)

    table_output=$(printf "%s,%s\n" \
        "User" "$user_val" \
        "Password" "$pass_val" \
        "Keyboard Layout" "$keymap_label" \
        "Hostname" "$hostname_val" \
        "Disk" "$disk_val" | \
        gum table \
            --print \
            --separator "," \
            --columns "Field,Value" \
            --widths 22,28 \
            --border "rounded")

    term_width=$(tput cols 2>/dev/null || echo 80)
    while IFS= read -r l; do
        clean_line=$(echo -e "$l" | sed 's/\x1b\[[0-9;]*m//g')
        left=$(( (term_width - ${#clean_line}) / 2 ))
        [ "$left" -lt 0 ] && left=0
        printf "%*s%s\n" "$left" "" "$l"
    done <<< "$table_output"
}

basic_ask_continue_or_change() {
    local label="$1"
    local value="$2"
    local back_fn="$3"
    local choice

    choice=$(gum choose \
        "Continue with current $label: $value" \
        "Change $label" \
        "← Back")

    case "$choice" in
        "Continue with current $label: $value")
            return 0
            ;;
        "Change $label")
            return 1
            ;;
        "← Back")
            "$back_fn"
            return 2
            ;;
    esac
}

# Step 1: Keyboard Layout
basic_step_1_keyboard() {
    local selected_option selected_keymap current_keymap current_locale selected_locale_option selected_locale
    show_banner
    gum style --foreground 212 "Step 1/14: Language & Keyboard"

    current_keymap=$(cat /tmp/asiraos/keymap 2>/dev/null || true)
    current_locale=$(cat /tmp/asiraos/locale 2>/dev/null || true)
    if [ -n "$current_keymap" ] && [ -n "$current_locale" ]; then
        basic_ask_continue_or_change "language settings" "$(basic_keymap_label "$current_keymap"), $current_locale" "main_menu"
        case $? in
            0) basic_step_3_timezone; return ;;
            2) return ;;
        esac
    fi

    selected_option=$(gum choose \
        "English (US) - us" \
        "English (UK) - uk" \
        "German (DE) - de" \
        "French (FR) - fr" \
        "Spanish (ES) - es" \
        "Italian (IT) - it" \
        "Russian (RU) - ru" \
        "Japanese (JP) - jp106" \
        "Portuguese (BR) - br-abnt2")

    if [ -n "$selected_option" ]; then
        selected_keymap=$(echo "$selected_option" | sed 's/.* - //')
        echo "$selected_keymap" > /tmp/asiraos/keymap
        loadkeys "$selected_keymap" >/dev/null 2>&1 || true
        gum style --foreground 46 "Keyboard layout set to: $selected_option"
    fi

    selected_locale_option=$(gum choose \
        "English (US) - en_US.UTF-8" \
        "English (UK) - en_GB.UTF-8" \
        "German (Germany) - de_DE.UTF-8" \
        "French (France) - fr_FR.UTF-8" \
        "Spanish (Spain) - es_ES.UTF-8" \
        "Italian (Italy) - it_IT.UTF-8" \
        "Portuguese (Brazil) - pt_BR.UTF-8" \
        "Russian (Russia) - ru_RU.UTF-8" \
        "Japanese (Japan) - ja_JP.UTF-8" \
        "Chinese (China) - zh_CN.UTF-8")

    if [ -n "$selected_locale_option" ]; then
        selected_locale=$(echo "$selected_locale_option" | sed 's/.* - //')
        echo "$selected_locale" > /tmp/asiraos/locale
        gum style --foreground 46 "Locale set to: $selected_locale_option"
    fi

    basic_step_3_timezone
}

# Step 3: Timezone Selection
basic_step_3_timezone() {
    local current_timezone
    show_banner
    gum style --foreground 212 "Step 2/14: Timezone Selection"

    current_timezone=$(cat /tmp/asiraos/timezone 2>/dev/null || true)
    if [ -n "$current_timezone" ]; then
        basic_ask_continue_or_change "timezone" "$current_timezone" "basic_step_1_keyboard"
        case $? in
            0) basic_step_4_mirror; return ;;
            2) return ;;
        esac
    fi

    SKIP_NEXT_BANNER=true
    timezone_selection
}

# Step 4: Mirror Selection
basic_step_4_mirror() {
    local current_mirror
    show_banner
    gum style --foreground 212 "Step 3/14: Mirror Selection"

    current_mirror=$(cat /tmp/asiraos/mirror_country 2>/dev/null || true)
    if [ -n "$current_mirror" ]; then
        basic_ask_continue_or_change "mirror" "$current_mirror" "basic_step_3_timezone"
        case $? in
            0) basic_step_5_desktop; return ;;
            2) return ;;
        esac
    fi

    SKIP_NEXT_BANNER=true
    mirror_selection
}

# Step 5: Desktop Environment
basic_step_5_desktop() {
    local current_desktop
    show_banner
    gum style --foreground 212 "Step 4/14: Desktop Environment"

    current_desktop=$(cat /tmp/asiraos/desktop 2>/dev/null || true)
    if [ -n "$current_desktop" ]; then
        basic_ask_continue_or_change "desktop environment" "$current_desktop" "basic_step_4_mirror"
        case $? in
            0) basic_step_6_drivers; return ;;
            2) return ;;
        esac
    fi

    SKIP_NEXT_BANNER=true
    desktop_selection
}

# Step 6: Driver Selection
basic_step_6_drivers() {
    local drivers_count
    show_banner
    gum style --foreground 212 "Step 5/14: Graphics Driver"

    if [ -f "/tmp/asiraos/drivers" ]; then
        drivers_count=$(grep -cve '^\s*$' -e 'Skip Driver Selection' /tmp/asiraos/drivers 2>/dev/null || true)
        if [ "${drivers_count:-0}" -gt 0 ]; then
            basic_ask_continue_or_change "graphics driver" "${drivers_count} selected" "basic_step_5_desktop"
            case $? in
                0) basic_step_7_packages; return ;;
                2) return ;;
            esac
        fi
    fi

    SKIP_NEXT_BANNER=true
    driver_selection
}

# Step 7: Package Selection
basic_step_7_packages() {
    local package_count choice
    show_banner
    gum style --foreground 212 "Step 6/14: Additional Programs"

    package_count=$(sort /tmp/asiraos/packages 2>/dev/null | uniq | wc -l | tr -d ' ')
    if [ "${package_count:-0}" -gt 0 ]; then
        basic_ask_continue_or_change "additional packages" "${package_count} selected" "basic_step_6_drivers"
        case $? in
            0) basic_step_8_user; return ;;
            2) return ;;
        esac
    fi

    choice=$(gum choose "Select Additional Packages" "Skip Package Selection")
    case "$choice" in
        "Select Additional Packages")
            SKIP_NEXT_BANNER=true
            package_selection
            ;;
        "Skip Package Selection")
            basic_step_8_user
            ;;
    esac
}

# Step 8: User Creation
basic_step_8_user() {
    show_banner
    gum style --foreground 212 "Step 7/14: User Creation"

    if [ -n "${USERNAME:-}" ] && [ -n "${PASSWORD:-}" ]; then
        basic_ask_continue_or_change "user" "$USERNAME" "basic_step_7_packages"
        case $? in
            0) basic_step_9_hostname; return ;;
            2) return ;;
        esac
    fi

    SKIP_NEXT_BANNER=true
    user_creation
}

# Step 9: Hostname Selection
basic_step_9_hostname() {
    local current_hostname
    show_banner
    gum style --foreground 212 "Step 8/14: Hostname Selection"

    current_hostname=$(cat /tmp/asiraos/hostname 2>/dev/null || true)
    if [ -n "$current_hostname" ]; then
        basic_ask_continue_or_change "hostname" "$current_hostname" "basic_step_8_user"
        case $? in
            0) basic_step_10_swap; return ;;
            2) return ;;
        esac
    fi

    SKIP_NEXT_BANNER=true
    hostname_selection
}

# Step 10: Swap Configuration
basic_step_10_swap() {
    local current_swap
    show_banner
    gum style --foreground 212 "Step 9/14: Swap Configuration"

    current_swap=$(cat /tmp/asiraos/swap 2>/dev/null || true)
    if [ -n "$current_swap" ]; then
        basic_ask_continue_or_change "swap" "$current_swap" "basic_step_9_hostname"
        case $? in
            0) basic_step_11_bootloader; return ;;
            2) return ;;
        esac
    fi

    SKIP_NEXT_BANNER=true
    swap_config
}

# Step 11: Bootloader Selection
basic_step_11_bootloader() {
    local current_bootloader
    show_banner
    gum style --foreground 212 "Step 10/14: Bootloader Selection"

    current_bootloader=$(cat /tmp/asiraos/bootloader 2>/dev/null || true)
    if [ -n "$current_bootloader" ]; then
        basic_ask_continue_or_change "bootloader" "$current_bootloader" "basic_step_10_swap"
        case $? in
            0) basic_step_12_kernel; return ;;
            2) return ;;
        esac
    fi

    SKIP_NEXT_BANNER=true
    bootloader_selection
}

# Step 12: Kernel Selection
basic_step_12_kernel() {
    local current_kernel
    show_banner
    gum style --foreground 212 "Step 11/14: Kernel Selection"

    current_kernel=$(cat /tmp/asiraos/kernel 2>/dev/null || true)
    if [ -n "$current_kernel" ]; then
        basic_ask_continue_or_change "kernel" "$current_kernel" "basic_step_11_bootloader"
        case $? in
            0) basic_step_13_network; return ;;
            2) return ;;
        esac
    fi

    SKIP_NEXT_BANNER=true
    kernel_selection
}

# Step 13: Network Detection
basic_step_13_network() {
    show_banner
    gum style --foreground 212 "Step 12/14: Network Check"

    SKIP_NEXT_BANNER=true
    network_detection
}

# Step 14: Disk Selection
basic_step_14_disk() {
    show_banner
    gum style --foreground 212 "Step 13/14: Disk Selection"

    SKIP_NEXT_BANNER=true
    disk_selection
}

# Step 15: Ready to Install
basic_step_15_install() {
    local choice
    show_banner
    gum style --foreground 212 "Step 14/14: Review and Install"

    choice=$(gum choose "Continue to Install" "← Back")
    case "$choice" in
        "Continue to Install")
            SKIP_NEXT_BANNER=true
            install_system
            ;;
        "← Back")
            if [ "${BASIC_RESUME_MODE:-false}" = "true" ]; then
                BASIC_RESUME_MODE=false
                basic_start_menu
            else
                basic_step_14_disk
            fi
            ;;
    esac
}

# Compatibility aliases for callbacks in other modules.
basic_step_1_disk() { basic_step_14_disk; }
basic_step_2_locale() { basic_step_1_keyboard; }
basic_step_3_locale() { basic_step_1_keyboard; }
basic_install() { basic_step_15_install; }
