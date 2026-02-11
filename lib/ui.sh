#!/bin/bash

# Shared UI helpers for centered terminal layout.

ui_term_width() {
    local width
    width=$(tput cols 2>/dev/null || echo 80)
    if [ -z "$width" ] || [ "$width" -lt 40 ]; then
        width=80
    fi
    echo "$width"
}

ui_block_width() {
    # Match the user's centering formula: LEFT=$(( WIDTH / 2 - 18 ))
    echo 36
}

ui_center_offset() {
    # Positive moves UI right, negative moves left.
    echo 3
}

ui_left_pad() {
    local width block pad
    width=$(ui_term_width)
    block=$(ui_block_width)
    pad=$(( width / 2 - (block / 2) + $(ui_center_offset) ))
    if [ "$pad" -lt 0 ]; then
        pad=0
    fi
    echo "$pad"
}

ui_spaces() {
    local count="${1:-0}"
    printf "%*s" "$count" ""
}

ui_center_text() {
    local text="${1:-}"
    local width pad visible_len
    width=$(ui_term_width)
    visible_len=${#text}
    pad=$(( (width - visible_len) / 2 ))
    if [ "$pad" -lt 0 ]; then
        pad=0
    fi
    printf "%s%s\n" "$(ui_spaces "$pad")" "$text"
}

ui_setup_centered_gum() {
    GUM_BIN=$(type -P gum)
    if [ -z "$GUM_BIN" ]; then
        return 1
    fi
    export GUM_BIN
}

ui_left_pad_for_text() {
    local text="${1:-}"
    local width text_len left
    width=$(ui_term_width)
    text_len=${#text}
    left=$(( width / 2 - (text_len / 2) + $(ui_center_offset) ))
    if [ "$left" -lt 0 ]; then
        left=0
    fi
    echo "$left"
}

gum() {
    local cmd="$1"
    shift || true

    if [ -z "${GUM_BIN:-}" ]; then
        GUM_BIN=$(type -P gum)
    fi

    if [ -z "${GUM_BIN:-}" ]; then
        return 127
    fi

    case "$cmd" in
        style)
            _ui_gum_style "$@"
            ;;
        choose)
            _ui_gum_choose "$@"
            ;;
        input)
            _ui_gum_input "$@"
            ;;
        filter)
            _ui_gum_filter "$@"
            ;;
        confirm)
            _ui_gum_confirm "$@"
            ;;
        *)
            "$GUM_BIN" "$cmd" "$@"
            ;;
    esac
}

_ui_gum_style() {
    local has_align=0
    local has_width=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            --align|--align=*)
                has_align=1
                ;;
            --width|--width=*)
                has_width=1
                ;;
        esac
    done

    if [ "$has_align" -eq 0 ] && [ "$has_width" -eq 0 ]; then
        "$GUM_BIN" style --align center --width "$(ui_term_width)" "$@"
    elif [ "$has_align" -eq 0 ]; then
        "$GUM_BIN" style --align center "$@"
    elif [ "$has_width" -eq 0 ]; then
        "$GUM_BIN" style --width "$(ui_term_width)" "$@"
    else
        "$GUM_BIN" style "$@"
    fi
}

_ui_gum_choose() {
    local left
    left=$(ui_left_pad)
    "$GUM_BIN" choose "$@" \
        --cursor "> " \
        --cursor-prefix "" \
        --selected-prefix "* " \
        --unselected-prefix "  " \
        --padding "0 0 0 ${left}"
}

_ui_gum_input() {
    local left
    left=$(ui_left_pad)
    "$GUM_BIN" input "$@" --prompt "> " --padding "0 0 0 ${left}"
}

_ui_gum_filter() {
    local left
    left=$(ui_left_pad)
    "$GUM_BIN" filter "$@" --prompt "> " --padding "0 0 0 ${left}"
}

_ui_gum_confirm() {
    local left prompt
    prompt="Confirm?"
    if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
        prompt="$1"
    fi
    left=$(ui_left_pad_for_text "$prompt")

    if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
        "$GUM_BIN" confirm "$@" --padding "0 0 0 ${left}"
    else
        "$GUM_BIN" confirm "$@" --padding "0 0 0 ${left}"
    fi
}
