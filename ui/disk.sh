#!/bin/bash

# Get real disk and partition information
get_real_disks() {
    # Prefer lsblk: it is more consistent across environments than parsing parted output.
    local lsblk_list
    lsblk_list=$(lsblk -dnpo NAME,SIZE,TYPE 2>/dev/null | awk '
        $3=="disk" {
            if ($1 ~ /\/dev\/(loop|ram|zram|fd)/) next
            print $1" "$2
        }')
    if [ -n "$lsblk_list" ]; then
        echo "$lsblk_list" | while read -r dev size; do
            [ -b "$dev" ] && echo "$dev $size"
        done
        return
    fi

    parted -m -s -l 2>/dev/null | awk -F: '
        /^\/dev\// {
            dev=$1; size=$2
            if (dev ~ /\/dev\/(loop|ram|zram|fd)/) next
            print dev " " size
        }'
}

get_real_partitions() {
    local disk=$1
    local disk_name part_num part_dev part_size part_fstype part_mount part_role
    disk_name=$(basename "$disk")

    while IFS='|' read -r entry_type entry_part _start _end size_mib entry_fs entry_flags; do
        [ "$entry_type" = "PART" ] || continue
        [ -n "$entry_part" ] || continue

        part_dev=$(partition_path "$disk_name" "$entry_part")
        [ -b "$part_dev" ] || continue

        part_size=$(lsblk -dnro SIZE "$part_dev" 2>/dev/null | head -1)
        [ -z "$part_size" ] && part_size="$(humanize_mib "$size_mib")"

        part_fstype=$(lsblk -dnro FSTYPE "$part_dev" 2>/dev/null | head -1)
        [ -z "$part_fstype" ] && part_fstype="$entry_fs"
        [ -z "$part_fstype" ] && part_fstype="unformatted"

        part_mount=$(lsblk -dnro MOUNTPOINT "$part_dev" 2>/dev/null | head -1)
        [ -z "$part_mount" ] && part_mount="-"

        part_role=""
        if [[ "$entry_flags" == *esp* ]] || [[ "$part_fstype" =~ ^(vfat|fat|fat16|fat32)$ ]]; then
            part_role="EFI-System"
        fi

        echo "${part_dev}|${part_size}|${part_fstype}|${part_mount}|${part_role}"
    done < <(get_parted_layout "$disk")
}

get_partition_fstype() {
    local partition="$1"
    local fs
    fs=$(lsblk -dnro FSTYPE "$partition" 2>/dev/null | head -1)
    if [ -z "$fs" ]; then
        fs=$(blkid -o value -s TYPE "$partition" 2>/dev/null | head -1)
    fi
    echo "${fs,,}"
}

is_efi_fs_type() {
    case "${1,,}" in
        vfat|fat|fat16|fat32) return 0 ;;
        *) return 1 ;;
    esac
}

get_free_regions() {
    local disk=$1
    parted -m -s "$disk" unit MiB print free 2>/dev/null | awk -F: '
        function n(v) { gsub(/[^0-9.]/, "", v); return v + 0 }
        $0 ~ /:free;$/ || $5 ~ /free/ {
            start=n($2); stop=n($3); size=n($4)
            if (stop > start && size > 1) {
                printf "%.2f %.2f %.2f\n", start, stop, size
            }
        }
    '
}

get_parted_layout() {
    local disk=$1
    parted -m -s "$disk" unit MiB print free 2>/dev/null | awk -F: '
        function n(v) { gsub(/[^0-9.]/, "", v); return v + 0 }
        $1 ~ /^[0-9]+$/ {
            start=n($2); stop=n($3); size=n($4)
            fs=tolower($5); flags=tolower($7)
            if (stop <= start || size <= 0) next

            if (fs == "free" || $0 ~ /:free;$/) {
                printf "FREE||%.2f|%.2f|%.2f||\n", start, stop, size
            } else {
                printf "PART|%s|%.2f|%.2f|%.2f|%s|%s\n", $1, start, stop, size, fs, flags
            }
        }
    '
}

get_free_space() {
    local disk=$1
    # Keep compatibility: return largest region as "start size" with MiB units.
    get_free_regions "$disk" | awk '
        {
            if ($3 + 0 > max) {
                max=$3 + 0
                s=$1
                z=$3
            }
        }
        END {
            if (max > 0) printf "%.2fMiB %.2fMiB\n", s, z
        }
    '
}

humanize_mib() {
    local mib="$1"
    awk -v m="$mib" 'BEGIN { if (m >= 1024) printf "%.2fGiB", (m/1024); else printf "%.0fMiB", m }'
}

partition_path() {
    local disk="$1"
    local partnum="$2"
    disk="${disk#/dev/}"
    if [[ "$disk" =~ [0-9]$ ]]; then
        echo "/dev/${disk}p${partnum}"
    else
        echo "/dev/${disk}${partnum}"
    fi
}

find_efi_partition_on_disk() {
    local disk="$1"
    local partnum
    partnum=$(parted -m -s "$disk" print 2>/dev/null | awk -F: '
        $1 ~ /^[0-9]+$/ {
            fs=tolower($5); flags=tolower($7)
            if (flags ~ /esp/ || fs ~ /fat32|fat16|fat/) {
                print $1
                exit
            }
        }')
    if [ -n "$partnum" ]; then
        partition_path "$disk" "$partnum"
    fi
}

is_efi_boot_mode() {
    [ -d /sys/firmware/efi ]
}

requires_boot_mount() {
    is_efi_boot_mode
}

set_bios_boot_target() {
    local disk="$1"
    [ -z "$disk" ] && return 1
    mkdir -p /tmp/asiraos
    echo "/dev/$disk" > /tmp/asiraos/boot_target
}

ensure_bios_boot_target() {
    local root_part root_disk
    is_efi_boot_mode && return 0

    if [ -f /tmp/asiraos/boot_target ] && [ -b "$(cat /tmp/asiraos/boot_target 2>/dev/null)" ]; then
        return 0
    fi

    root_part=$(grep " -> /$" /tmp/asiraos/mounts 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$root_part" ] && [ -b "$root_part" ]; then
        root_disk=$(lsblk -no PKNAME "$root_part" 2>/dev/null | head -1)
    fi

    DISK_OPTIONS=()
    while read -r disk_line; do
        local disk_name disk_size
        disk_name=$(echo "$disk_line" | awk '{print $1}' | sed 's|/dev/||')
        disk_size=$(echo "$disk_line" | awk '{print $2}')
        if [ -n "$root_disk" ] && [ "$disk_name" = "$root_disk" ]; then
            DISK_OPTIONS+=("$disk_name ($disk_size, recommended)")
        else
            DISK_OPTIONS+=("$disk_name ($disk_size)")
        fi
    done < <(get_real_disks)

    if [ ${#DISK_OPTIONS[@]} -eq 0 ]; then
        gum style --foreground 196 "No disks found for BIOS boot target selection"
        return 1
    fi

    gum style --foreground 214 "Select whole disk for BIOS bootloader installation:"
    local selected option_disk
    selected=$(gum choose --cursor-prefix "> " --selected-prefix "* " "${DISK_OPTIONS[@]}")
    option_disk=$(echo "$selected" | awk '{print $1}')
    option_disk="${option_disk#/dev/}"

    if [ -z "$option_disk" ] || [ ! -b "/dev/$option_disk" ]; then
        gum style --foreground 196 "Invalid disk selection"
        return 1
    fi

    set_bios_boot_target "$option_disk"
    gum style --foreground 46 "Bootloader install target: /dev/$option_disk"
    return 0
}

# Get the highest existing partition number on a disk (0 if none)
get_last_partition_number() {
    local disk=$1
    local disk_name
    disk_name=$(basename "$disk")
    lsblk -ln -o NAME "$disk" | awk -v d="$disk_name" '
        NR>1 {
            n=$1
            sub("^"d, "", n)
            sub("^p", "", n)
            if (n ~ /^[0-9]+$/ && n+0 > max) max = n+0
        }
        END { print max+0 }
    '
}
# Disk Selection
disk_selection() {
    show_banner
    gum style --foreground 214 "Disk Selection"
    echo ""
    
    # Show selected mountpoints under title
    if [ -f "/tmp/asiraos/mounts" ]; then
        gum style --foreground 46 "Selected Mountpoints:"
        table_output=$(awk -F ' -> ' 'NF==2 {print $1 "," $2}' /tmp/asiraos/mounts | \
            gum table --columns "Partition,Mountpoint" --widths 28,16 --print)
        term_width=$(tput cols 2>/dev/null || echo 80)
        while IFS= read -r l; do
            clean_line=$(echo -e "$l" | sed 's/\x1b\[[0-9;]*m//g')
            left=$(( (term_width - ${#clean_line}) / 2 ))
            [ "$left" -lt 0 ] && left=0
            printf "%*s%s\n" "$left" "" "$l"
        done <<< "$table_output"
        echo ""
    fi
    
    # Check if we have required mountpoints
    HAS_ROOT=false
    HAS_BOOT=true
    if [ -f "/tmp/asiraos/mounts" ]; then
        if grep -q " -> /$" /tmp/asiraos/mounts; then
            HAS_ROOT=true
        fi
        if requires_boot_mount; then
            HAS_BOOT=false
            if grep -q " -> /boot/efi$" /tmp/asiraos/mounts || grep -q " -> /boot$" /tmp/asiraos/mounts; then
                HAS_BOOT=true
            fi
        fi
    fi
    
    # Build menu options - remove "Recommended" if partitions are configured
    if [ "$HAS_ROOT" = true ] && [ "$HAS_BOOT" = true ]; then
        MENU_OPTIONS=("🚀 Continue to Next Step" "Auto Partition" "Custom Partition Setup")
    else
        MENU_OPTIONS=("Auto Partition (Recommended)" "Custom Partition Setup")
    fi
    
    # Add clear option if mounts exist
    if [ -f "/tmp/asiraos/mounts" ]; then
        MENU_OPTIONS+=("Clear All Mountpoints")
    fi
    
    MENU_OPTIONS+=("← Back")
    
    CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " "${MENU_OPTIONS[@]}")
    
    case $CHOICE in
        "Custom Partition Setup")
            manual_partition
            ;;
        "Auto Partition (Recommended)"|"Auto Partition")
            auto_partition
            ;;
        "Clear All Mountpoints")
            rm -f /tmp/asiraos/mounts
            rm -f /tmp/asiraos/boot_target
            gum style --foreground 46 "All mountpoints cleared"
            sleep 1
            disk_selection
            ;;
        "🚀 Continue to Next Step")
            mount_partitions_and_continue
            ;;
        "← Back")
            if [ "$BASIC_MODE" = true ]; then
                basic_step_1_disk
            else
                advanced_setup
            fi
            ;;
    esac
}

mount_partitions_and_continue() {
    gum style --foreground 205 "Mounting partitions..."

    if ! ensure_bios_boot_target; then
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    # Unmount any existing mounts
    umount -R /mnt 2>/dev/null || true
    
    # Mount root partition first
    ROOT_PARTITION=$(grep " -> /$" /tmp/asiraos/mounts | cut -d' ' -f1 | head -1)
    if [ -n "$ROOT_PARTITION" ]; then
        gum style --foreground 46 "Mounting root: $ROOT_PARTITION -> /mnt"
        mount "$ROOT_PARTITION" /mnt
    fi
    
    # Mount other partitions
    while IFS= read -r line; do
        PARTITION=$(echo "$line" | cut -d' ' -f1)
        MOUNTPOINT=$(echo "$line" | cut -d' ' -f3)
        
        # Skip root partition (already mounted)
        if [ "$MOUNTPOINT" = "/" ]; then
            continue
        fi
        
        # Create mountpoint and mount
        mkdir -p "/mnt$MOUNTPOINT"
        gum style --foreground 46 "Mounting: $PARTITION -> /mnt$MOUNTPOINT"
        
        if [ "$MOUNTPOINT" = "/boot/efi" ]; then
            mount -t vfat "$PARTITION" "/mnt$MOUNTPOINT"
        elif [ "$MOUNTPOINT" = "/boot" ]; then
            mount "$PARTITION" "/mnt$MOUNTPOINT"
        else
            mount "$PARTITION" "/mnt$MOUNTPOINT"
        fi
    done < /tmp/asiraos/mounts
    
    gum style --foreground 46 "✓ All partitions mounted successfully"
    sleep 1
    
    if [ "$BASIC_MODE" = true ]; then
        basic_step_15_install
    else
        advanced_setup
    fi
}

# Manual Partition
manual_partition() {
    show_banner
    gum style --foreground 214 "Manual Partition"
    echo ""
    
    # Get real available disks
    DISK_OPTIONS=()
    while read -r disk_line; do
        disk_name=$(echo "$disk_line" | awk '{print $1}' | sed 's|/dev/||')
        disk_size=$(echo "$disk_line" | awk '{print $2}')
        DISK_OPTIONS+=("$disk_name ($disk_size)")
    done < <(get_real_disks)
    
    if [ ${#DISK_OPTIONS[@]} -eq 0 ]; then
        gum style --foreground 196 "No disks found"
        gum input --placeholder "Press Enter to go back..."
        disk_selection
        return
    fi
    
    # Let user select disk
    gum style --foreground 46 "Select disk:"
    SELECTED_OPTION=$(gum choose --cursor-prefix "> " --selected-prefix "* " "${DISK_OPTIONS[@]}")
    DISK=$(echo "$SELECTED_OPTION" | cut -d' ' -f1)
    
    CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "Create/Edit Partitions (cfdisk)" \
        "Set Mountpoints" \
        "← Back")
    
    case $CHOICE in
        "Create/Edit Partitions (cfdisk)")
            gum style --foreground 214 "Opening cfdisk for /dev/$DISK"
            sleep 1
            cfdisk /dev/$DISK
            partprobe /dev/$DISK 2>/dev/null || true
            if command -v udevadm >/dev/null 2>&1; then
                udevadm settle 2>/dev/null || true
            fi
            echo -e "${GREEN}Partitioning completed for /dev/$DISK${NC}"
            gum input --placeholder "Press Enter to continue..."
            manual_partition
            ;;
        "Set Mountpoints")
            set_mountpoints "$DISK"
            ;;
        "← Back")
            disk_selection
            ;;
    esac
}

# Set Mountpoints with proper partition detection
set_mountpoints() {
    local disk=$1
    show_banner
    gum style --foreground 214 "Set Mountpoints for /dev/$disk"
    echo ""
    
    # Get real partitions for this disk
    PARTITION_OPTIONS=()
    PARTITION_VALUES=()
    while IFS='|' read -r part_dev part_size part_fstype part_mount part_role; do
        if [ -n "$part_dev" ]; then
            part_name="${part_dev#/dev/}"
            [ -z "$part_fstype" ] && part_fstype="unformatted"

            if [ -n "$part_role" ]; then
                PARTITION_OPTIONS+=("$part_name ($part_size, $part_fstype, $part_role)")
            else
                PARTITION_OPTIONS+=("$part_name ($part_size, $part_fstype)")
            fi
            PARTITION_VALUES+=("$part_name")
        fi
    done < <(get_real_partitions "/dev/$disk")
    
    if [ ${#PARTITION_OPTIONS[@]} -eq 0 ]; then
        gum style --foreground 214 "No partitions found on /dev/$disk"
        gum style --foreground 214 "Please create partitions first using cfdisk"
        gum input --placeholder "Press Enter to go back..."
        manual_partition
        return
    fi
    
    # Let user select partition
    gum style --foreground 46 "Select partition:"
    SELECTED_OPTION=$(gum choose --cursor-prefix "> " --selected-prefix "* " "${PARTITION_OPTIONS[@]}")
    PARTITION=""
    for i in "${!PARTITION_OPTIONS[@]}"; do
        if [ "${PARTITION_OPTIONS[$i]}" = "$SELECTED_OPTION" ]; then
            PARTITION="${PARTITION_VALUES[$i]}"
            break
        fi
    done

    # Normalize partition name (remove /dev/ if already present)
    PARTITION="${PARTITION#/dev/}"

    # Verify partition exists
    if [ ! -b "/dev/$PARTITION" ]; then
        gum style --foreground 196 "Error: Partition /dev/$PARTITION not found"
        gum input --placeholder "Press Enter to try again..."
        set_mountpoints "$disk"
        return
    fi

    
    # Select mountpoint
    if is_efi_boot_mode; then
        MOUNTPOINT=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
            "/" \
            "/boot" \
            "/boot/efi" \
            "/home" \
            "/var" \
            "/tmp" \
            "Custom")
    else
        gum style --foreground 46 "BIOS mode: select root partition for /"
        MOUNTPOINT="/"
    fi
    
    if [ "$MOUNTPOINT" = "Custom" ]; then
        MOUNTPOINT=$(gum input --placeholder "Enter custom mountpoint (e.g., /opt)")
    fi
    
    # Check if mountpoint already exists
    if grep -q " -> $MOUNTPOINT$" /tmp/asiraos/mounts 2>/dev/null; then
        gum style --foreground 196 "Mountpoint $MOUNTPOINT already exists!"
        gum input --placeholder "Press Enter to try again..."
        set_mountpoints "$disk"
        return
    fi
    
    # Ask if user wants to format the partition
    FORMAT_CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "Format partition" \
        "Use existing filesystem")
    
    if [ "$FORMAT_CHOICE" = "Format partition" ]; then
        format_partition "/dev/$PARTITION" "$MOUNTPOINT"
    elif is_efi_boot_mode && { [ "$MOUNTPOINT" = "/boot" ] || [ "$MOUNTPOINT" = "/boot/efi" ]; }; then
        CURRENT_FS=$(get_partition_fstype "/dev/$PARTITION")
        if ! is_efi_fs_type "$CURRENT_FS"; then
            gum style --foreground 196 "EFI boot mount requires FAT32 (EFI System) partition"
            gum input --placeholder "Press Enter to choose again..."
            set_mountpoints "$disk"
            return
        fi
    fi
    
    # Save mountpoint configuration
    mkdir -p /tmp/asiraos
    echo "/dev/$PARTITION -> $MOUNTPOINT" >> /tmp/asiraos/mounts
    if [ "$MOUNTPOINT" = "/" ] && ! is_efi_boot_mode; then
        ROOT_DISK=$(lsblk -no PKNAME "/dev/$PARTITION" 2>/dev/null | head -1)
        [ -n "$ROOT_DISK" ] && set_bios_boot_target "$ROOT_DISK"
    fi
    gum style --foreground 46 "Mountpoint set: /dev/$PARTITION -> $MOUNTPOINT"

    if ! is_efi_boot_mode; then
        gum style --foreground 46 "BIOS root partition configured. Continue to next step."
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "Set Another Mountpoint" \
        "🚀 Continue to Disk Selection" \
        "← Back")
    
    case $CHOICE in
        "Set Another Mountpoint")
            set_mountpoints "$disk"
            ;;
        "🚀 Continue to Disk Selection")
            disk_selection
            ;;
        "← Back")
            manual_partition
            ;;
    esac
}

# Create partition in free space
create_partition_in_free_space() {
    local disk=$1
    
    gum style --foreground 205 "Creating new partition in free space..."
    
    # Get free space info
    FREE_SPACE_INFO=$(get_free_space "/dev/$disk")
    FREE_START=$(echo "$FREE_SPACE_INFO" | awk '{print $1}')
    FREE_SIZE=$(echo "$FREE_SPACE_INFO" | awk '{print $2}')
    
    if [ -z "$FREE_START" ] || [ -z "$FREE_SIZE" ]; then
        gum style --foreground 196 "No free space available"
        gum input --placeholder "Press Enter to continue..."
        set_mountpoints "$disk"
        return
    fi
    
    # Get partition size from user
    PART_SIZE=$(gum input --placeholder "Enter partition size (e.g., 20GB, 50%, or 'all' for remaining space)")
    
    if [ -z "$PART_SIZE" ]; then
        gum style --foreground 196 "Invalid size"
        gum input --placeholder "Press Enter to try again..."
        create_partition_in_free_space "$disk"
        return
    fi
    
    FREE_START_MIB=$(echo "$FREE_START" | sed 's/[^0-9.]//g')
    FREE_SIZE_MIB=$(echo "$FREE_SIZE" | sed 's/[^0-9.]//g')
    FREE_END_MIB=$(awk -v s="$FREE_START_MIB" -v z="$FREE_SIZE_MIB" 'BEGIN {printf "%.2f", s+z}')

    # Calculate end position
    if [ "$PART_SIZE" = "all" ]; then
        END_POS="${FREE_END_MIB}MiB"
    elif [[ "$PART_SIZE" == *"%" ]]; then
        pct=$(echo "$PART_SIZE" | tr -d '%')
        if ! [[ "$pct" =~ ^[0-9]+$ ]] || [ "$pct" -lt 1 ] || [ "$pct" -gt 100 ]; then
            gum style --foreground 196 "Invalid percentage size"
            gum input --placeholder "Press Enter to try again..."
            create_partition_in_free_space "$disk"
            return
        fi
        END_POS=$(awk -v s="$FREE_START_MIB" -v z="$FREE_SIZE_MIB" -v p="$pct" 'BEGIN {printf "%.2fMiB", s + (z * p / 100)}')
    else
        SIZE_MIB=$(echo "$PART_SIZE" | sed -E 's/[Gg][Bb]?$//' | awk '{print $1 * 1024}')
        END_POS=$(awk -v s="$FREE_START_MIB" -v z="$SIZE_MIB" 'BEGIN {printf "%.2fMiB", s + z}')
    fi

    END_POS_MIB=$(echo "$END_POS" | sed 's/[^0-9.]//g')
    if awk "BEGIN {exit !($END_POS_MIB > $FREE_END_MIB)}"; then
        gum style --foreground 196 "Requested size exceeds free space region"
        gum input --placeholder "Press Enter to try again..."
        create_partition_in_free_space "$disk"
        return
    fi
    
    # Get next partition number
    LAST_PART=$(get_last_partition_number "/dev/$disk")
    NEXT_PART=$((LAST_PART + 1))
    
    # Create partition
    gum style --foreground 205 "Creating partition $NEXT_PART..."
    parted "/dev/$disk" mkpart primary ext4 "$FREE_START" "$END_POS" --script
    
    # Wait for kernel to recognize new partition
    sleep 2
    partprobe "/dev/$disk"
    udevadm settle
    
    # Construct partition device name
    NEW_PARTITION=$(partition_path "$disk" "$NEXT_PART" | sed 's|^/dev/||')
    
    # Verify partition was created
    if [ -b "/dev/$NEW_PARTITION" ]; then
        gum style --foreground 46 "✓ Partition /dev/$NEW_PARTITION created successfully"
        # Continue with mountpoint selection for the new partition
        set_mountpoints_for_partition "$NEW_PARTITION"
    else
        gum style --foreground 196 "Failed to create partition"
        gum input --placeholder "Press Enter to continue..."
        set_mountpoints "$disk"
    fi
}

# Set mountpoints for a specific partition
set_mountpoints_for_partition() {
    local partition=$1
    
    gum style --foreground 46 "Setting mountpoint for /dev/$partition"
    
    # Select mountpoint
    if is_efi_boot_mode; then
        MOUNTPOINT=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
            "/" \
            "/boot" \
            "/boot/efi" \
            "/home" \
            "/var" \
            "/tmp" \
            "Custom")
    else
        gum style --foreground 46 "BIOS mode: new partition will be used as /"
        MOUNTPOINT="/"
    fi
    
    if [ "$MOUNTPOINT" = "Custom" ]; then
        MOUNTPOINT=$(gum input --placeholder "Enter custom mountpoint (e.g., /opt)")
    fi
    
    # Check if mountpoint already exists
    if grep -q " -> $MOUNTPOINT$" /tmp/asiraos/mounts 2>/dev/null; then
        gum style --foreground 196 "Mountpoint $MOUNTPOINT already exists!"
        gum input --placeholder "Press Enter to try again..."
        set_mountpoints_for_partition "$partition"
        return
    fi
    
    # Format the new partition
    format_partition "/dev/$partition" "$MOUNTPOINT"
    
    # Save mountpoint configuration
    mkdir -p /tmp/asiraos
    echo "/dev/$partition -> $MOUNTPOINT" >> /tmp/asiraos/mounts
    if [ "$MOUNTPOINT" = "/" ] && ! is_efi_boot_mode; then
        ROOT_DISK=$(lsblk -no PKNAME "/dev/$partition" 2>/dev/null | head -1)
        [ -n "$ROOT_DISK" ] && set_bios_boot_target "$ROOT_DISK"
    fi
    gum style --foreground 46 "Mountpoint set: /dev/$partition -> $MOUNTPOINT"

    if ! is_efi_boot_mode; then
        gum style --foreground 46 "BIOS root partition configured. Continue to next step."
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    disk_selection
}

# Format partition based on mountpoint
format_partition() {
    local partition=$1
    local mountpoint=$2
    
    if is_efi_boot_mode && { [ "$mountpoint" = "/boot/efi" ] || [ "$mountpoint" = "/boot" ]; }; then
        gum style --foreground 205 "Formatting $partition as EFI System (FAT32)..."
        mkfs.fat -F32 "$partition"
    elif [ "$mountpoint" = "/boot/efi" ]; then
        gum style --foreground 205 "Formatting $partition as EFI System (FAT32)..."
        mkfs.fat -F32 "$partition"
    elif [ "$mountpoint" = "/boot" ]; then
        # Check if system is EFI or BIOS
        if [ -d "/sys/firmware/efi" ]; then
            # EFI system - format as FAT32
            FS_TYPE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
                "EFI System (FAT32)")
            gum style --foreground 205 "Formatting $partition as EFI System (FAT32)..."
            mkfs.fat -F32 "$partition"
        else
            # BIOS/MBR system - show regular filesystem options
            FS_TYPE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
                "ext4" \
                "ext3" \
                "xfs" \
                "btrfs")
            
            case $FS_TYPE in
                "ext4")
                    gum style --foreground 205 "Formatting $partition as ext4..."
                    mkfs.ext4 "$partition"
                    ;;
                "ext3")
                    gum style --foreground 205 "Formatting $partition as ext3..."
                    mkfs.ext3 "$partition"
                    ;;
                "xfs")
                    gum style --foreground 205 "Formatting $partition as xfs..."
                    mkfs.xfs "$partition"
                    ;;
                "btrfs")
                    gum style --foreground 205 "Formatting $partition as btrfs..."
                    mkfs.btrfs "$partition"
                    ;;
            esac
        fi
    else
        # Ask user for filesystem type
        FS_TYPE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
            "ext4" \
            "ext3" \
            "xfs" \
            "btrfs")
        
        case $FS_TYPE in
            "ext4")
                gum style --foreground 205 "Formatting $partition as ext4..."
                mkfs.ext4 "$partition"
                ;;
            "ext3")
                gum style --foreground 205 "Formatting $partition as ext3..."
                mkfs.ext3 "$partition"
                ;;
            "xfs")
                gum style --foreground 205 "Formatting $partition as xfs..."
                mkfs.xfs "$partition"
                ;;
            "btrfs")
                gum style --foreground 205 "Formatting $partition as btrfs..."
                mkfs.btrfs "$partition"
                ;;
        esac
    fi
    gum style --foreground 46 "✓ Formatting completed"
}

# Auto Partition with proper disk detection
auto_partition() {
    show_banner
    gum style --foreground 214 "Auto Partition"
    echo ""
    rm -f /tmp/asiraos/boot_target

    # Detect boot mode
    if [ -d /sys/firmware/efi ]; then
        BOOT_MODE="EFI"
        BOOT_MOUNTPOINT="/boot/efi"
        gum style --foreground 46 "✓ EFI boot mode detected"
    else
        BOOT_MODE="BIOS"
        BOOT_MOUNTPOINT=""
        gum style --foreground 46 "✓ BIOS boot mode detected"
    fi
    echo ""

    gum style --foreground 46 "Detecting available storage..."
    DISK_OPTIONS=()
    while read -r disk size; do
        [ -z "$disk" ] && continue
        [ ! -b "$disk" ] && continue
        disk_name=$(basename "$disk")
        DISK_OPTIONS+=("$disk_name ($size)")
    done < <(get_real_disks)

    [ ${#DISK_OPTIONS[@]} -eq 0 ] && {
        gum style --foreground 196 "No storage devices found"
        gum input --placeholder "Press Enter..."
        return
    }

    gum style --foreground 46 "Select disk:"
    SELECTED_DISK_UI=$(gum choose --cursor-prefix "> " --selected-prefix "* " "${DISK_OPTIONS[@]}")
    TARGET_DISK=$(echo "$SELECTED_DISK_UI" | awk '{print $1}')
    TARGET_DISK="${TARGET_DISK#/dev/}"
    [ -z "$TARGET_DISK" ] && return
    [ ! -b "/dev/$TARGET_DISK" ] && {
        gum style --foreground 196 "Invalid disk selected: /dev/$TARGET_DISK"
        gum input --placeholder "Press Enter..."
        return
    }

    # Build target options for selected disk only (from parted layout).
    ALL_OPTIONS=()
    DISPLAY=()

    disk_size=$(echo "$SELECTED_DISK_UI" | sed -E 's/^[^ ]+ \((.*)\)$/\1/')
    ALL_OPTIONS+=("DISK|$TARGET_DISK|$disk_size")
    DISPLAY+=("/dev/$TARGET_DISK ($disk_size) - Whole Disk")

    while IFS='|' read -r entry_type part_num start_mib end_mib size_mib fstype flags; do
        [ -z "$entry_type" ] && continue
        if [ "$entry_type" = "PART" ]; then
            part_dev=$(partition_path "$TARGET_DISK" "$part_num")
            part_name=$(basename "$part_dev")
            part_fstype=${fstype:-unformatted}
            ALL_OPTIONS+=("PART|$TARGET_DISK|$part_num|$size_mib|$part_fstype|$flags")
            DISPLAY+=("  ├─ partition: /dev/$part_name ($(humanize_mib "$size_mib"), $part_fstype)")
        elif [ "$entry_type" = "FREE" ]; then
            if awk "BEGIN {exit !($size_mib >= 512)}"; then
                ALL_OPTIONS+=("FREE|$TARGET_DISK|$size_mib|$start_mib|$end_mib")
                DISPLAY+=("  └─ free space: $(humanize_mib "$size_mib") (${start_mib}MiB-${end_mib}MiB)")
            fi
        fi
    done < <(get_parted_layout "/dev/$TARGET_DISK")

    TARGET_OPTION=$(gum choose --cursor-prefix "> " --selected-prefix "* " "${DISPLAY[@]}")
    TARGET_INDEX=-1
    for i in "${!DISPLAY[@]}"; do
        if [ "${DISPLAY[$i]}" = "$TARGET_OPTION" ]; then
            TARGET_INDEX="$i"
            break
        fi
    done
    [ "$TARGET_INDEX" -lt 0 ] && return
    IFS='|' read -r TYPE FIELD2 FIELD3 FIELD4 FIELD5 FIELD6 <<< "${ALL_OPTIONS[$TARGET_INDEX]}"

    echo ""
    case "$TYPE" in
        DISK) gum style --foreground 46 "Selected: Whole Disk → /dev/$FIELD2" ;;
        PART)
            TARGET_PART_PREVIEW=$(partition_path "$FIELD2" "$FIELD3")
            gum style --foreground 46 "Selected: Partition → $TARGET_PART_PREVIEW"
            ;;
        FREE) gum style --foreground 46 "Selected: Free Space → /dev/$FIELD2 (${FIELD4}MiB-${FIELD5}MiB)" ;;
    esac

    # ---- MODE ----
    case "$TYPE" in
        DISK)
            MODE="wholedisk"
            TARGET_DISK="$FIELD2"
            ;;
        FREE)
            MODE="freespace"
            TARGET_DISK="$FIELD2"
            TARGET_FREE_START="$FIELD4"
            TARGET_FREE_END="$FIELD5"
            ;;
        PART)
            MODE="partition"
            TARGET_DISK="$FIELD2"
            TARGET_PART_NUM="$FIELD3"
            TARGET_PART=$(partition_path "$TARGET_DISK" "$TARGET_PART_NUM")
            ;;
    esac

    gum style --foreground 196 "⚠ This may ERASE data"
    CONFIRM=$(gum choose "Yes" "No")
    [ "$CONFIRM" = "No" ] && return

    # ---- PARTITION SCHEME ----
    if [ "$BOOT_MODE" = "EFI" ]; then
        SCHEME=$(gum choose \
            "Basic (Boot + Root)" \
            "Standard (Boot + Root + Home)")
    else
        SCHEME=$(gum choose \
            "Basic (Root only)" \
            "Standard (Root + Home)")
    fi

    umount -R /mnt 2>/dev/null || true

    case "$MODE" in
        wholedisk)
            wipefs -af "/dev/$TARGET_DISK" 2>/dev/null || true
            if [ "$BOOT_MODE" = "BIOS" ]; then
                set_bios_boot_target "$TARGET_DISK"
            fi
            if [ "$SCHEME" = "Standard (Boot + Root + Home)" ] || [ "$SCHEME" = "Standard (Root + Home)" ]; then
                create_standard_partitions_wholedisk "$TARGET_DISK"
            else
                create_basic_partitions_wholedisk "$TARGET_DISK"
            fi
            return
            ;;
        freespace)
            if [ "$BOOT_MODE" = "BIOS" ]; then
                set_bios_boot_target "$TARGET_DISK"
            fi
            if [ "$SCHEME" = "Standard (Boot + Root + Home)" ] || [ "$SCHEME" = "Standard (Root + Home)" ]; then
                create_standard_partitions_freespace "$TARGET_DISK" "$TARGET_FREE_START" "$TARGET_FREE_END"
            else
                create_basic_partitions_freespace "$TARGET_DISK" "$TARGET_FREE_START" "$TARGET_FREE_END"
            fi
            return
            ;;
        partition)
            rm -f /tmp/asiraos/mounts
            mkdir -p /tmp/asiraos

            gum style --foreground 205 "Formatting $TARGET_PART as ext4..."
            mkfs.ext4 -F "$TARGET_PART"
            echo "$TARGET_PART -> /" >> /tmp/asiraos/mounts

            if [ "$BOOT_MODE" = "EFI" ]; then
                PARENT_DISK=$(lsblk -no PKNAME "$TARGET_PART" | head -1)
                if [ -n "$PARENT_DISK" ]; then
                    EFI_PART=$(find_efi_partition_on_disk "/dev/$PARENT_DISK")
                    if [ -z "$EFI_PART" ]; then
                        EFI_PART=$(lsblk -rno NAME,FSTYPE,PARTTYPE "/dev/$PARENT_DISK" | awk '
                            $2 ~ /vfat|fat32/ {print "/dev/"$1; exit}
                            $3 ~ /c12a7328-f81f-11d2-ba4b-00a0c93ec93b/ {print "/dev/"$1; exit}
                        ')
                    fi
                    if [ -n "$EFI_PART" ]; then
                        echo "$EFI_PART -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
                    else
                        gum style --foreground 196 "EFI partition not found on /dev/$PARENT_DISK"
                        gum input --placeholder "Press Enter to continue..."
                        disk_selection
                        return
                    fi
                fi
            fi

            if [ "$BOOT_MODE" = "BIOS" ]; then
                PARENT_DISK=$(lsblk -no PKNAME "$TARGET_PART" | head -1)
                [ -n "$PARENT_DISK" ] && set_bios_boot_target "$PARENT_DISK"
            fi

            partition_complete
            return
            ;;
    esac
}



# Create basic partitions on whole disk
create_basic_partitions_wholedisk() {
    local disk=$1
    gum style --foreground 205 "Creating basic partitions on whole disk /dev/${disk}..."
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Unmount any existing partitions
    umount /dev/${disk}* 2>/dev/null || true
    swapoff /dev/${disk}* 2>/dev/null || true
    
    # Create new partition table
    if [ "$BOOT_MODE" = "EFI" ]; then
        gum style --foreground 205 "Creating GPT partition table..."
        parted /dev/$disk mklabel gpt --script
        
        gum style --foreground 205 "Creating EFI Boot partition (1GB)"
        parted /dev/$disk mkpart primary fat32 1MB 1025MB --script
        parted /dev/$disk set 1 boot on --script
        
        gum style --foreground 205 "Creating Root partition (remaining space)"
        parted /dev/$disk mkpart primary ext4 1025MB 100% --script
    else
        gum style --foreground 205 "Creating MBR partition table..."
        parted /dev/$disk mklabel msdos --script

        gum style --foreground 205 "Creating Root partition (whole disk)"
        parted /dev/$disk mkpart primary ext4 1MB 100% --script
    fi
    
    # Wait for kernel to recognize partitions
    sleep 3
    partprobe /dev/$disk
    udevadm settle
    
    # Construct partition device names
    ROOT_DEV=$(partition_path "$disk" 2)
    if [ "$BOOT_MODE" = "BIOS" ]; then
        ROOT_DEV=$(partition_path "$disk" 1)
    fi

    # Format partitions
    gum style --foreground 205 "Formatting partitions..."
    if [ "$BOOT_MODE" = "EFI" ]; then
        BOOT_DEV=$(partition_path "$disk" 1)
        mkfs.fat -F32 "$BOOT_DEV"
        echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    fi
    mkfs.ext4 "$ROOT_DEV"

    # Save mountpoints
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    
    gum style --foreground 46 "✓ Basic partitions created successfully"
    partition_complete
}

# Create standard partitions on whole disk
create_standard_partitions_wholedisk() {
    local disk=$1
    gum style --foreground 205 "Creating standard partitions on whole disk /dev/${disk}..."
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Unmount any existing partitions
    umount /dev/${disk}* 2>/dev/null || true
    swapoff /dev/${disk}* 2>/dev/null || true
    
    # Create new partition table
    if [ "$BOOT_MODE" = "EFI" ]; then
        parted /dev/$disk mklabel gpt --script
        
        gum style --foreground 205 "Creating EFI Boot partition (1GB)"
        parted /dev/$disk mkpart primary fat32 1MB 1025MB --script
        parted /dev/$disk set 1 boot on --script
        
        gum style --foreground 205 "Creating Root partition (30GB)"
        parted /dev/$disk mkpart primary ext4 1025MB 31745MB --script
        
        gum style --foreground 205 "Creating Home partition (remaining space)"
        parted /dev/$disk mkpart primary ext4 31745MB 100% --script
    else
        parted /dev/$disk mklabel msdos --script

        gum style --foreground 205 "Creating Root partition (30GB)"
        parted /dev/$disk mkpart primary ext4 1MB 30721MB --script

        gum style --foreground 205 "Creating Home partition (remaining space)"
        parted /dev/$disk mkpart primary ext4 30721MB 100% --script
    fi
    
    # Wait for kernel to recognize partitions
    sleep 3
    partprobe /dev/$disk
    udevadm settle
    
    # Construct partition device names
    ROOT_DEV=$(partition_path "$disk" 2)
    HOME_DEV=$(partition_path "$disk" 3)
    if [ "$BOOT_MODE" = "BIOS" ]; then
        ROOT_DEV=$(partition_path "$disk" 1)
        HOME_DEV=$(partition_path "$disk" 2)
    fi

    # Format partitions
    gum style --foreground 205 "Formatting partitions..."
    if [ "$BOOT_MODE" = "EFI" ]; then
        BOOT_DEV=$(partition_path "$disk" 1)
        mkfs.fat -F32 "$BOOT_DEV"
        echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    fi
    mkfs.ext4 "$ROOT_DEV"
    mkfs.ext4 "$HOME_DEV"

    # Save mountpoints
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    echo "$HOME_DEV -> /home" >> /tmp/asiraos/mounts
    
    gum style --foreground 46 "✓ Standard partitions created successfully"
    partition_complete
}

# Create custom partitions on whole disk
create_custom_partitions_wholedisk() {
    local disk=$1
    echo -e "${CYAN}Creating custom partitions on whole disk /dev/${disk}...${NC}"
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Ask for additional partitions
    ADDITIONAL_PARTITIONS=$(gum choose --no-limit --cursor-prefix "> " --selected-prefix "* " \
        "Home partition" \
        "Var partition" \
        "Tmp partition")
    
    # Unmount any existing partitions
    umount /dev/${disk}* 2>/dev/null || true
    swapoff /dev/${disk}* 2>/dev/null || true
    
    # Create new partition table
    if [ "$BOOT_MODE" = "EFI" ]; then
        parted /dev/$disk mklabel gpt --script
        
        echo -e "${CYAN}- Creating EFI Boot partition (1GB)${NC}"
        parted /dev/$disk mkpart primary fat32 1MB 1025MB --script
        parted /dev/$disk set 1 boot on --script
        
        echo -e "${CYAN}- Creating Root partition (30GB)${NC}"
        parted /dev/$disk mkpart primary ext4 1025MB 31745MB --script
        
        local next_start=31745
        local part_num=3
    else
        parted /dev/$disk mklabel msdos --script
        
        echo -e "${CYAN}- Creating BIOS Boot partition (512MB)${NC}"
        parted /dev/$disk mkpart primary ext4 1MB 513MB --script
        parted /dev/$disk set 1 boot on --script
        
        echo -e "${CYAN}- Creating Root partition (30GB)${NC}"
        parted /dev/$disk mkpart primary ext4 513MB 31233MB --script
        
        local next_start=31233
        local part_num=3
    fi
    
    # Create additional partitions
    if [[ $ADDITIONAL_PARTITIONS == *"Var partition"* ]]; then
        echo -e "${CYAN}- Creating Var partition (10GB)${NC}"
        local var_end=$((next_start + 10240))
        parted /dev/$disk mkpart primary ext4 ${next_start}MB ${var_end}MB --script
        next_start=$var_end
        ((part_num++))
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Tmp partition"* ]]; then
        echo -e "${CYAN}- Creating Tmp partition (5GB)${NC}"
        local tmp_end=$((next_start + 5120))
        parted /dev/$disk mkpart primary ext4 ${next_start}MB ${tmp_end}MB --script
        next_start=$tmp_end
        ((part_num++))
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Home partition"* ]]; then
        echo -e "${CYAN}- Creating Home partition (remaining space)${NC}"
        parted /dev/$disk mkpart primary ext4 ${next_start}MB 100% --script
        ((part_num++))
    fi
    
    # Wait for kernel to recognize partitions
    sleep 3
    partprobe /dev/$disk
    udevadm settle
    
    # Format and save mountpoints
    local current_part=1
    
    # Boot partition
    BOOT_DEV=$(partition_path "$disk" "$current_part")
    
    mkfs.fat -F32 "$BOOT_DEV"
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    ((current_part++))
    
    # Root partition
    ROOT_DEV=$(partition_path "$disk" "$current_part")
    mkfs.ext4 "$ROOT_DEV"
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    ((current_part++))
    
    # Additional partitions
    if [[ $ADDITIONAL_PARTITIONS == *"Var partition"* ]]; then
        VAR_DEV=$(partition_path "$disk" "$current_part")
        mkfs.ext4 "$VAR_DEV"
        echo "$VAR_DEV -> /var" >> /tmp/asiraos/mounts
        ((current_part++))
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Tmp partition"* ]]; then
        TMP_DEV=$(partition_path "$disk" "$current_part")
        mkfs.ext4 "$TMP_DEV"
        echo "$TMP_DEV -> /tmp" >> /tmp/asiraos/mounts
        ((current_part++))
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Home partition"* ]]; then
        HOME_DEV=$(partition_path "$disk" "$current_part")
        mkfs.ext4 "$HOME_DEV"
        echo "$HOME_DEV -> /home" >> /tmp/asiraos/mounts
        ((current_part++))
    fi
    
    echo -e "${GREEN}✓ Custom partitions created successfully${NC}"
    partition_complete
}

# Create basic partitions in free space - FIXED VERSION
create_basic_partitions_freespace() {
    local disk=$1
    local selected_start_mib=$2
    local selected_end_mib=$3
    
    echo -e "${CYAN}Creating basic partitions in free space on /dev/${disk}...${NC}"
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Get real free space information
    if [ -n "$selected_start_mib" ] && [ -n "$selected_end_mib" ]; then
        FREE_START_MIB="$selected_start_mib"
        FREE_END_MIB="$selected_end_mib"
    else
        FREE_REGION=$(get_free_regions "/dev/$disk" | awk 'BEGIN{m=0} { if($3>m){m=$3; s=$1; e=$2} } END { if(m>0) print s" "e" "m }')
        if [ -z "$FREE_REGION" ]; then
            gum style --foreground 196 "ERROR: No free space found on /dev/$disk"
            gum input --placeholder "Press Enter to continue..."
            disk_selection
            return
        fi
        FREE_START_MIB=$(echo "$FREE_REGION" | awk '{print $1}')
        FREE_END_MIB=$(echo "$FREE_REGION" | awk '{print $2}')
    fi

    FREE_SIZE_MIB=$(awk -v s="$FREE_START_MIB" -v e="$FREE_END_MIB" 'BEGIN {printf "%.2f", (e-s)}')
    if awk "BEGIN {exit !($FREE_SIZE_MIB <= 0)}"; then
        gum style --foreground 196 "ERROR: No free space found on /dev/$disk"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi

    REQUIRED_MIB=2048
    if [ "$BOOT_MODE" = "EFI" ]; then
        REQUIRED_MIB=3072
    fi
    if awk "BEGIN {exit !($FREE_SIZE_MIB < $REQUIRED_MIB)}"; then
        gum style --foreground 196 "ERROR: Not enough free space available in selected region"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    echo -e "${GREEN}Found free space: $(humanize_mib "$FREE_SIZE_MIB") starting at ${FREE_START_MIB}MiB${NC}"
    
    # Get next available partition numbers
    LAST_PART=$(get_last_partition_number "/dev/$disk")
    if [ "$BOOT_MODE" = "EFI" ]; then
        BOOT_PART=$((LAST_PART + 1))
        ROOT_PART=$((LAST_PART + 2))
        echo -e "${GREEN}Will create partitions: $BOOT_PART (boot) and $ROOT_PART (root)${NC}"
    else
        ROOT_PART=$((LAST_PART + 1))
        echo -e "${GREEN}Will create partition: $ROOT_PART (root)${NC}"
    fi
    
    # Unmount any existing partitions on this disk
    umount /dev/${disk}* 2>/dev/null || true
    swapoff /dev/${disk}* 2>/dev/null || true
    
    # Create partitions based on boot mode
    if [ "$BOOT_MODE" = "EFI" ]; then
        BOOT_END=$(awk -v s="$FREE_START_MIB" 'BEGIN {printf "%.2fMiB", s + 1024}')
        FREE_START="${FREE_START_MIB}MiB"
        FREE_END="${FREE_END_MIB}MiB"
        
        echo -e "${CYAN}Creating EFI boot partition: $FREE_START to $BOOT_END${NC}"
        parted "/dev/$disk" mkpart primary fat32 "$FREE_START" "$BOOT_END" --script
        parted "/dev/$disk" set "$BOOT_PART" esp on --script 2>/dev/null || true
        parted "/dev/$disk" set "$BOOT_PART" boot on --script
        
        echo -e "${CYAN}Creating root partition: $BOOT_END to $FREE_END${NC}"
        parted "/dev/$disk" mkpart primary ext4 "$BOOT_END" "$FREE_END" --script
    else
        FREE_START="${FREE_START_MIB}MiB"
        FREE_END="${FREE_END_MIB}MiB"
        echo -e "${CYAN}Creating root partition: $FREE_START to $FREE_END${NC}"
        parted "/dev/$disk" mkpart primary ext4 "$FREE_START" "$FREE_END" --script
    fi
    
    # Wait for kernel to recognize new partitions
    echo -e "${CYAN}Waiting for system to recognize new partitions...${NC}"
    sleep 3
    partprobe "/dev/$disk"
    udevadm settle
    sleep 2
    
    # Construct partition device names
    ROOT_DEV=$(partition_path "$disk" "$ROOT_PART")
    if [ "$BOOT_MODE" = "EFI" ]; then
        BOOT_DEV=$(partition_path "$disk" "$BOOT_PART")
    fi

    # Verify partitions were created
    if [ "$BOOT_MODE" = "EFI" ] && [ ! -b "$BOOT_DEV" ]; then
        gum style --foreground 196 "ERROR: Boot partition $BOOT_DEV was not created"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    if [ ! -b "$ROOT_DEV" ]; then
        gum style --foreground 196 "ERROR: Root partition $ROOT_DEV was not created"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    # Format partitions
    echo -e "${CYAN}Formatting partitions...${NC}"
    if [ "$BOOT_MODE" = "EFI" ]; then
        echo -e "${GREEN}Formatting $BOOT_DEV as FAT32...${NC}"
        mkfs.fat -F32 "$BOOT_DEV"
    fi
    
    echo -e "${GREEN}Formatting $ROOT_DEV as ext4...${NC}"
    mkfs.ext4 "$ROOT_DEV"
    
    # Save mountpoints
    if [ "$BOOT_MODE" = "EFI" ]; then
        echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    fi
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    
    echo -e "${GREEN}✓ Basic partitions created successfully in free space${NC}"
    if [ "$BOOT_MODE" = "EFI" ]; then
        echo -e "${GREEN}Boot: $BOOT_DEV -> $BOOT_MOUNTPOINT${NC}"
    fi
    echo -e "${GREEN}Root: $ROOT_DEV -> /${NC}"
    
    partition_complete
}

# Create standard partitions in free space - FIXED VERSION
create_standard_partitions_freespace() {
    local disk=$1
    local selected_start_mib=$2
    local selected_end_mib=$3
    echo -e "${CYAN}Creating standard partitions in free space on /dev/${disk}...${NC}"
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Get real free space information
    if [ -n "$selected_start_mib" ] && [ -n "$selected_end_mib" ]; then
        FREE_START_MIB="$selected_start_mib"
        FREE_END_MIB="$selected_end_mib"
    else
        FREE_REGION=$(get_free_regions "/dev/$disk" | awk 'BEGIN{m=0} { if($3>m){m=$3; s=$1; e=$2} } END { if(m>0) print s" "e" "m }')
        if [ -z "$FREE_REGION" ]; then
            gum style --foreground 196 "ERROR: No free space found"
            gum input --placeholder "Press Enter to continue..."
            disk_selection
            return
        fi
        FREE_START_MIB=$(echo "$FREE_REGION" | awk '{print $1}')
        FREE_END_MIB=$(echo "$FREE_REGION" | awk '{print $2}')
    fi

    FREE_SIZE_MIB=$(awk -v s="$FREE_START_MIB" -v e="$FREE_END_MIB" 'BEGIN {printf "%.2f", (e-s)}')
    BOOT_MIB=0
    [ "$BOOT_MODE" = "EFI" ] && BOOT_MIB=1024
    ROOT_MIB=30720
    REQUIRED_TOTAL_MIB=$(awk -v b="$BOOT_MIB" -v r="$ROOT_MIB" 'BEGIN {print b + r + 1024}')
    if awk "BEGIN {exit !($FREE_SIZE_MIB < $REQUIRED_TOTAL_MIB)}"; then
        gum style --foreground 196 "ERROR: Selected free region is too small for Standard scheme"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi

    FREE_START="${FREE_START_MIB}MiB"
    FREE_END="${FREE_END_MIB}MiB"

    if [ -z "$FREE_START_MIB" ] || [ -z "$FREE_END_MIB" ]; then
        gum style --foreground 196 "ERROR: No free space found"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    # Get next available partition numbers
    LAST_PART=$(get_last_partition_number "/dev/$disk")
    if [ "$BOOT_MODE" = "EFI" ]; then
        BOOT_PART=$((LAST_PART + 1))
        ROOT_PART=$((LAST_PART + 2))
        HOME_PART=$((LAST_PART + 3))
    else
        ROOT_PART=$((LAST_PART + 1))
        HOME_PART=$((LAST_PART + 2))
    fi
    
    # Create partitions
    if [ "$BOOT_MODE" = "EFI" ]; then
        BOOT_END=$(awk -v s="$FREE_START_MIB" 'BEGIN {printf "%.2fMiB", s + 1024}')
        ROOT_END=$(awk -v s="$FREE_START_MIB" 'BEGIN {printf "%.2fMiB", s + 1024 + 30720}')
        
        parted "/dev/$disk" mkpart primary fat32 "$FREE_START" "$BOOT_END" --script
        parted "/dev/$disk" set "$BOOT_PART" esp on --script 2>/dev/null || true
        parted "/dev/$disk" set "$BOOT_PART" boot on --script
        parted "/dev/$disk" mkpart primary ext4 "$BOOT_END" "$ROOT_END" --script
        parted "/dev/$disk" mkpart primary ext4 "$ROOT_END" "$FREE_END" --script
    else
        ROOT_END=$(awk -v s="$FREE_START_MIB" 'BEGIN {printf "%.2fMiB", s + 30720}')
        parted "/dev/$disk" mkpart primary ext4 "$FREE_START" "$ROOT_END" --script
        parted "/dev/$disk" mkpart primary ext4 "$ROOT_END" "$FREE_END" --script
    fi
    
    # Wait for kernel recognition
    sleep 3
    partprobe "/dev/$disk"
    udevadm settle
    
    # Construct device names
    ROOT_DEV=$(partition_path "$disk" "$ROOT_PART")
    HOME_DEV=$(partition_path "$disk" "$HOME_PART")
    if [ "$BOOT_MODE" = "EFI" ]; then
        BOOT_DEV=$(partition_path "$disk" "$BOOT_PART")
        mkfs.fat -F32 "$BOOT_DEV"
    fi
    mkfs.ext4 "$ROOT_DEV"
    mkfs.ext4 "$HOME_DEV"
    
    # Save mountpoints
    if [ "$BOOT_MODE" = "EFI" ]; then
        echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    fi
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    echo "$HOME_DEV -> /home" >> /tmp/asiraos/mounts
    
    echo -e "${GREEN}✓ Standard partitions created successfully in free space${NC}"
    partition_complete
}

# Create custom partitions in free space - FIXED VERSION
create_custom_partitions_freespace() {
    local disk=$1
    echo -e "${CYAN}Creating custom partitions in free space on /dev/${disk}...${NC}"
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Ask for additional partitions first
    ADDITIONAL_PARTITIONS=$(gum choose --no-limit --cursor-prefix "> " --selected-prefix "* " \
        "Home partition" \
        "Var partition" \
        "Tmp partition")
    
    # Get real free space information
    FREE_SPACE_INFO=$(get_free_space "/dev/$disk")
    if [ -z "$FREE_SPACE_INFO" ]; then
        gum style --foreground 196 "ERROR: No free space found"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    FREE_START=$(echo "$FREE_SPACE_INFO" | awk '{print $1}')
    
    # Get next available partition numbers
    LAST_PART=$(get_last_partition_number "/dev/$disk")
    PART_NUM=$((LAST_PART + 1))
    
    # Create boot partition
    if [ "$BOOT_MODE" = "EFI" ]; then
        CURRENT_END=$(echo "$FREE_START" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 1}')
        parted "/dev/$disk" mkpart primary fat32 "$FREE_START" "$CURRENT_END" --script
        parted "/dev/$disk" set "$PART_NUM" boot on --script
    else
        CURRENT_END=$(echo "$FREE_START" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 0.5}')
        parted "/dev/$disk" mkpart primary ext4 "$FREE_START" "$CURRENT_END" --script
        parted "/dev/$disk" set "$PART_NUM" boot on --script
    fi
    
    BOOT_PART=$PART_NUM
    ((PART_NUM++))
    
    # Create root partition (30GB)
    ROOT_END=$(echo "$CURRENT_END" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 30}')
    parted "/dev/$disk" mkpart primary ext4 "$CURRENT_END" "$ROOT_END" --script
    ROOT_PART=$PART_NUM
    ((PART_NUM++))
    CURRENT_END=$ROOT_END
    
    # Create additional partitions
    if [[ $ADDITIONAL_PARTITIONS == *"Var partition"* ]]; then
        VAR_END=$(echo "$CURRENT_END" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 10}')
        parted "/dev/$disk" mkpart primary ext4 "$CURRENT_END" "$VAR_END" --script
        VAR_PART=$PART_NUM
        ((PART_NUM++))
        CURRENT_END=$VAR_END
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Tmp partition"* ]]; then
        TMP_END=$(echo "$CURRENT_END" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 5}')
        parted "/dev/$disk" mkpart primary ext4 "$CURRENT_END" "$TMP_END" --script
        TMP_PART=$PART_NUM
        ((PART_NUM++))
        CURRENT_END=$TMP_END
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Home partition"* ]]; then
        parted "/dev/$disk" mkpart primary ext4 "$CURRENT_END" "100%" --script
        HOME_PART=$PART_NUM
        ((PART_NUM++))
    fi
    
    # Wait for kernel recognition
    sleep 3
    partprobe "/dev/$disk"
    udevadm settle
    
    # Format and save mountpoints
    BOOT_DEV=$(partition_path "$disk" "$BOOT_PART")
    ROOT_DEV=$(partition_path "$disk" "$ROOT_PART")
    
    # Format boot and root
    mkfs.fat -F32 "$BOOT_DEV"
    mkfs.ext4 "$ROOT_DEV"
    
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    
    # Format additional partitions
    if [[ $ADDITIONAL_PARTITIONS == *"Var partition"* ]]; then
        VAR_DEV=$(partition_path "$disk" "$VAR_PART")
        mkfs.ext4 "$VAR_DEV"
        echo "$VAR_DEV -> /var" >> /tmp/asiraos/mounts
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Tmp partition"* ]]; then
        TMP_DEV=$(partition_path "$disk" "$TMP_PART")
        mkfs.ext4 "$TMP_DEV"
        echo "$TMP_DEV -> /tmp" >> /tmp/asiraos/mounts
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Home partition"* ]]; then
        HOME_DEV=$(partition_path "$disk" "$HOME_PART")
        mkfs.ext4 "$HOME_DEV"
        echo "$HOME_DEV -> /home" >> /tmp/asiraos/mounts
    fi
    
    echo -e "${GREEN}✓ Custom partitions created successfully in free space${NC}"
    partition_complete
}

# Partition completion
partition_complete() {
    gum style --foreground 46 "Partitioning completed successfully!"
    echo ""
    gum style --foreground 46 "Created mountpoints:"
    if [ -f "/tmp/asiraos/mounts" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && gum style --foreground 46 "$line"
        done < /tmp/asiraos/mounts
    fi
    echo ""
    
    CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "🚀 Continue to Disk Selection" \
        "View Partition Details")
    
    case $CHOICE in
        "🚀 Continue to Disk Selection")
            disk_selection
            ;;
        "View Partition Details")
            gum style --foreground 214 "Current partition layout:"
            while IFS= read -r line; do
                [ -n "$line" ] && gum style --foreground 46 "$line"
            done < <(lsblk)
            gum input --placeholder "Press Enter to continue..."
            disk_selection
            ;;
    esac
}
