#!/bin/bash
# AsiraOS - The Future of Linux
# Copyright (c) 2024 AsiraOS Team
# https://asiraos.github.io
# Licensed under GPL-3.0


# ASCII Art Banner
show_banner() {
    local script_dir logo_file left gum_bin
    if [ "${SKIP_NEXT_BANNER:-false}" = "true" ]; then
        SKIP_NEXT_BANNER=false
        return
    fi

    clear
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    logo_file="${script_dir}/logo.txt"

    if command -v tte >/dev/null 2>&1 && [ -f "$logo_file" ]; then
        tte -i "$logo_file" \
            --canvas-width 0 \
            --anchor-text c \
            --frame-rate 920 \
            laseretch
    else
        left=$(ui_left_pad)
        gum_bin="${GUM_BIN:-$(type -P gum)}"
        "$gum_bin" style --foreground 15 --bold --align left --padding "0 0 0 ${left}" \
" █████  ███████ ██ ██████   █████   ██████  ███████
██   ██ ██      ██ ██   ██ ██   ██ ██    ██ ██
███████ ███████ ██ ██████  ███████ ██    ██ ███████
██   ██      ██ ██ ██   ██ ██   ██ ██    ██      ██
██   ██ ███████ ██ ██   ██ ██   ██  ██████  ███████"
    fi

    echo ""
}
