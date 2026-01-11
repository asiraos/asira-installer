#!/bin/bash

# Get real disk and partition information
get_real_disks() {
    lsblk -dpno NAME,SIZE,TYPE | grep disk | while read -r name size type; do
        echo "$name $size"
    done
}

get_real_partitions() {
    local disk=$1
    lsblk -pno NAME,SIZE,FSTYPE,MOUNTPOINT "$disk" | grep -v "^$disk" | while read -r name size fstype mount; do
        echo "$name $size $fstype $mount"
    done
}

get_free_space() {
    local disk=$1
    parted "$disk" unit GB print free 2>/dev/null | grep "Free Space" | tail -1 | awk '{print $1 " " $3}'
}

# Disk Selection
disk_selection() {
    show_banner
    gum style --foreground 214 "Disk Selection"
    echo ""
    
    # Show selected mountpoints under title
    if [ -f "/tmp/asiraos/mounts" ]; then
        echo -e "${GREEN}Selected Mountpoints:${NC}"
        cat /tmp/asiraos/mounts
        echo ""
    fi
    
    # Check if we have root and boot partitions
    HAS_ROOT=false
    HAS_BOOT=false
    if [ -f "/tmp/asiraos/mounts" ]; then
        if grep -q " -> /$" /tmp/asiraos/mounts; then
            HAS_ROOT=true
        fi
        if grep -q " -> /boot/efi$" /tmp/asiraos/mounts || grep -q " -> /boot$" /tmp/asiraos/mounts; then
            HAS_BOOT=true
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
    
    MENU_OPTIONS+=("Go Back to Previous Menu")
    
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
            gum style --foreground 46 "All mountpoints cleared"
            sleep 1
            disk_selection
            ;;
        "🚀 Continue to Next Step")
            mount_partitions_and_continue
            ;;
        "Go Back to Previous Menu")
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
        
        # Skip root partition (already mounted) and swap
        if [ "$MOUNTPOINT" = "/" ] || [ "$MOUNTPOINT" = "swap" ]; then
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
        basic_step_3_locale
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
        "Go Back")
    
    case $CHOICE in
        "Create/Edit Partitions (cfdisk)")
            gum style --foreground 214 "Opening cfdisk for /dev/$DISK"
            sleep 1
            cfdisk /dev/$DISK
            echo -e "${GREEN}Partitioning completed for /dev/$DISK${NC}"
            gum input --placeholder "Press Enter to continue..."
            manual_partition
            ;;
        "Set Mountpoints")
            set_mountpoints "$DISK"
            ;;
        "Go Back")
            disk_selection
            ;;
    esac
}

# Set Mountpoints with proper partition detection
set_mountpoints() {
    local disk=$1
    show_banner
    echo -e "${CYAN}Set Mountpoints for /dev/$disk${NC}"
    echo ""
    
    # Get real partitions for this disk
    PARTITION_OPTIONS=()
    while read -r part_line; do
        if [ -n "$part_line" ]; then
            part_name=$(echo "$part_line" | awk '{print $1}' | sed 's|/dev/||')
            part_size=$(echo "$part_line" | awk '{print $2}')
            part_fstype=$(echo "$part_line" | awk '{print $3}')
            part_mount=$(echo "$part_line" | awk '{print $4}')
            
            if [ "$part_fstype" = "" ]; then
                part_fstype="unformatted"
            fi
            
            PARTITION_OPTIONS+=("$part_name ($part_size, $part_fstype)")
        fi
    done < <(get_real_partitions "/dev/$disk")
    
    # Check for real free space
    FREE_SPACE_INFO=$(get_free_space "/dev/$disk")
    if [ -n "$FREE_SPACE_INFO" ]; then
        FREE_START=$(echo "$FREE_SPACE_INFO" | awk '{print $1}')
        FREE_SIZE=$(echo "$FREE_SPACE_INFO" | awk '{print $2}')
        if [ "$FREE_SIZE" != "0GB" ] && [ "$FREE_SIZE" != "0.00GB" ]; then
            PARTITION_OPTIONS+=("FREE_SPACE ($FREE_SIZE available)")
        fi
    fi
    
    if [ ${#PARTITION_OPTIONS[@]} -eq 0 ]; then
        echo -e "${YELLOW}No partitions or free space found on /dev/$disk${NC}"
        echo -e "${YELLOW}Please create partitions first using cfdisk${NC}"
        gum input --placeholder "Press Enter to go back..."
        manual_partition
        return
    fi
    
    # Let user select partition
    echo -e "${GREEN}Select partition or free space:${NC}"
    SELECTED_OPTION=$(gum choose --cursor-prefix "> " --selected-prefix "* " "${PARTITION_OPTIONS[@]}")
    PARTITION=$(echo "$SELECTED_OPTION" | cut -d' ' -f1)
    


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
    MOUNTPOINT=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "/" \
        "/boot" \
        "/boot/efi" \
        "/home" \
        "/var" \
        "/tmp" \
        "swap" \
        "Custom")
    
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
    fi
    
    # Save mountpoint configuration
    mkdir -p /tmp/asiraos
    echo "/dev/$PARTITION -> $MOUNTPOINT" >> /tmp/asiraos/mounts
    echo -e "${GREEN}Mountpoint set: /dev/$PARTITION -> $MOUNTPOINT${NC}"
    
    CHOICE=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "Set Another Mountpoint" \
        "🚀 Continue to Disk Selection" \
        "Go Back")
    
    case $CHOICE in
        "Set Another Mountpoint")
            set_mountpoints "$disk"
            ;;
        "🚀 Continue to Disk Selection")
            disk_selection
            ;;
        "Go Back")
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
    
    if [ -z "$FREE_START" ] || [ "$FREE_SIZE" = "0GB" ]; then
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
    
    # Calculate end position
    if [ "$PART_SIZE" = "all" ]; then
        END_POS="100%"
    elif [[ "$PART_SIZE" == *"%" ]]; then
        END_POS="$PART_SIZE"
    else
        # Convert to MB and calculate end
        SIZE_MB=$(echo "$PART_SIZE" | sed 's/GB//' | awk '{print $1 * 1024}')
        START_MB=$(echo "$FREE_START" | sed 's/GB//' | awk '{print $1 * 1024}')
        END_MB=$((START_MB + SIZE_MB))
        END_POS="${END_MB}MB"
    fi
    
    # Get next partition number
    LAST_PART=$(parted "/dev/$disk" print 2>/dev/null | awk '/^ *[0-9]/ {last=$1} END {print last}')
    if [ -z "$LAST_PART" ]; then
        NEXT_PART=1
    else
        NEXT_PART=$((LAST_PART + 1))
    fi
    
    # Create partition
    gum style --foreground 205 "Creating partition $NEXT_PART..."
    parted "/dev/$disk" mkpart primary ext4 "$FREE_START" "$END_POS" --script
    
    # Wait for kernel to recognize new partition
    sleep 2
    partprobe "/dev/$disk"
    udevadm settle
    
    # Construct partition device name
    if [[ "$disk" =~ nvme ]]; then
        NEW_PARTITION="${disk}p${NEXT_PART}"
    else
        NEW_PARTITION="${disk}${NEXT_PART}"
    fi
    
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
    
    echo -e "${GREEN}Setting mountpoint for /dev/$partition${NC}"
    
    # Select mountpoint
    MOUNTPOINT=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "/" \
        "/boot" \
        "/boot/efi" \
        "/home" \
        "/var" \
        "/tmp" \
        "swap" \
        "Custom")
    
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
    echo -e "${GREEN}Mountpoint set: /dev/$partition -> $MOUNTPOINT${NC}"
    
    disk_selection
}

# Format partition based on mountpoint
format_partition() {
    local partition=$1
    local mountpoint=$2
    
    if [ "$mountpoint" = "/boot/efi" ]; then
        gum style --foreground 205 "Formatting $partition as FAT32..."
        mkfs.fat -F32 "$partition"
    elif [ "$mountpoint" = "swap" ]; then
        gum style --foreground 205 "Setting up swap on $partition..."
        mkswap "$partition"
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
    
    # Detect boot mode (EFI or BIOS)
    if [ -d "/sys/firmware/efi" ]; then
        BOOT_MODE="EFI"
        gum style --foreground 46 "✓ EFI boot mode detected"
        BOOT_MOUNTPOINT="/boot/efi"
    else
        BOOT_MODE="BIOS"
        gum style --foreground 46 "✓ BIOS boot mode detected"
        BOOT_MOUNTPOINT="/boot"
    fi
    echo ""
    
    # Get real available disks and partitions
    gum style --foreground 46 "Detecting available storage..."
    ALL_OPTIONS=()
    
    # Add whole disks
    while read -r disk_line; do
        if [ -n "$disk_line" ]; then
            disk_name=$(echo "$disk_line" | awk '{print $1}' | sed 's|/dev/||')
            disk_size=$(echo "$disk_line" | awk '{print $2}')
            ALL_OPTIONS+=("$disk_name ($disk_size) - Whole Disk")
        fi
    done < <(get_real_disks)
    
    # Add existing partitions
    while read -r disk_line; do
        if [ -n "$disk_line" ]; then
            disk_path=$(echo "$disk_line" | awk '{print $1}')
            disk_name=$(echo "$disk_path" | sed 's|/dev/||')
            
            while read -r part_line; do
                if [ -n "$part_line" ]; then
                    part_name=$(echo "$part_line" | awk '{print $1}' | sed 's|/dev/||')
                    part_size=$(echo "$part_line" | awk '{print $2}')
                    part_fstype=$(echo "$part_line" | awk '{print $3}')
                    
                    if [ "$part_fstype" = "" ]; then
                        part_fstype="unformatted"
                    fi
                    
                    ALL_OPTIONS+=(" └─ $part_name ($part_size, $part_fstype)")
                fi
            done < <(get_real_partitions "$disk_path")
            
            # Check for real free space
            FREE_SPACE_INFO=$(get_free_space "$disk_path")
            if [ -n "$FREE_SPACE_INFO" ]; then
                FREE_SIZE=$(echo "$FREE_SPACE_INFO" | awk '{print $2}')
                if [ "$FREE_SIZE" != "0GB" ] && [ "$FREE_SIZE" != "0.00GB" ]; then
                    ALL_OPTIONS+=(" └─ ${disk_name}-freespace ($FREE_SIZE free)")
                fi
            fi
        fi
    done < <(get_real_disks)
    
    if [ ${#ALL_OPTIONS[@]} -eq 0 ]; then
        gum style --foreground 196 "No storage devices found"
        gum input --placeholder "Press Enter to go back..."
        disk_selection
        return
    fi
    
    # Let user select storage
    gum style --foreground 46 "Select storage for installation:"
    SELECTED_OPTION=$(gum choose --cursor-prefix "> " --selected-prefix "* " "${ALL_OPTIONS[@]}")
    
    # Parse the selected option
    if [[ "$SELECTED_OPTION" =~ ^[[:space:]]*└─[[:space:]]*(.*) ]]; then
        # It's a partition or free space (indented)
        SELECTED_TARGET=$(echo "${BASH_REMATCH[1]}" | awk '{print $1}')
    else
        # It's a whole disk
        SELECTED_TARGET=$(echo "$SELECTED_OPTION" | awk '{print $1}')
    fi
    
    # Determine operation mode
    if [[ "$SELECTED_TARGET" =~ -freespace$ ]]; then
        # Free space mode
        PARENT_DISK=$(echo "$SELECTED_TARGET" | sed 's/-freespace$//')
        OPERATION_MODE="freespace"
        TARGET_DISK="$PARENT_DISK"
    elif [[ "$SELECTED_OPTION" =~ "Whole Disk" ]]; then
        # Whole disk mode
        OPERATION_MODE="wholedisk"
        TARGET_DISK="$SELECTED_TARGET"
    else
        # Single partition mode
        OPERATION_MODE="partition"
        TARGET_PARTITION="$SELECTED_TARGET"
        TARGET_DISK=$(echo "$SELECTED_TARGET" | sed 's/[0-9]*$//' | sed 's/p$//')
    fi
    
    # Show selection info
    echo ""
    echo -e "${GREEN}Selected: $SELECTED_OPTION${NC}"
    echo -e "${GREEN}Operation Mode: $OPERATION_MODE${NC}"
    echo ""
    
    # Show appropriate warning
    case $OPERATION_MODE in
        "wholedisk")
            gum style --foreground 196 "WARNING: This will erase ALL data on /dev/$TARGET_DISK"
            ;;
        "freespace")
            gum style --foreground 205 "INFO: Will create partitions in free space on /dev/$TARGET_DISK"
            ;;
        "partition")
            gum style --foreground 196 "WARNING: This will erase data on /dev/$TARGET_PARTITION"
            ;;
    esac
    
    CONFIRM=$(gum choose --cursor-prefix "> " --selected-prefix "* " "Yes" "No")
    
    if [ "$CONFIRM" = "No" ]; then
        disk_selection
        return
    fi
    
    # Partition scheme selection
    gum style --foreground 214 "Select partition scheme:"
    PARTITION_SCHEME=$(gum choose --cursor-prefix "> " --selected-prefix "* " \
        "Basic (Boot + Root only)" \
        "Standard (Boot + Root + Home)" \
        "Custom (Choose additional partitions)")
    
    # Execute partitioning based on mode and scheme
    case $OPERATION_MODE in
        "wholedisk")
            case $PARTITION_SCHEME in
                "Basic (Boot + Root only)")
                    create_basic_partitions_wholedisk "$TARGET_DISK"
                    ;;
                "Standard (Boot + Root + Home)")
                    create_standard_partitions_wholedisk "$TARGET_DISK"
                    ;;
                "Custom (Choose additional partitions)")
                    create_custom_partitions_wholedisk "$TARGET_DISK"
                    ;;
            esac
            ;;
        "freespace")
            case $PARTITION_SCHEME in
                "Basic (Boot + Root only)")
                    create_basic_partitions_freespace "$TARGET_DISK"
                    ;;
                "Standard (Boot + Root + Home)")
                    create_standard_partitions_freespace "$TARGET_DISK"
                    ;;
                "Custom (Choose additional partitions)")
                    create_custom_partitions_freespace "$TARGET_DISK"
                    ;;
            esac
            ;;
        "partition")
            gum style --foreground 205 "Using existing partition /dev/$TARGET_PARTITION as root"
            mkdir -p /tmp/asiraos
            echo "/dev/$TARGET_PARTITION -> /" > /tmp/asiraos/mounts
            gum style --foreground 46 "✓ Partition configured"
            partition_complete
            ;;
    esac
}

# Create basic partitions on whole disk
create_basic_partitions_wholedisk() {
    local disk=$1
    echo -e "${CYAN}Creating basic partitions on whole disk /dev/${disk}...${NC}"
    
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
        
        echo -e "${CYAN}- Creating EFI Boot partition (1GB)${NC}"
        parted /dev/$disk mkpart primary fat32 1MB 1025MB --script
        parted /dev/$disk set 1 boot on --script
        
        echo -e "${CYAN}- Creating Root partition (remaining space)${NC}"
        parted /dev/$disk mkpart primary ext4 1025MB 100% --script
    else
        gum style --foreground 205 "Creating MBR partition table..."
        parted /dev/$disk mklabel msdos --script
        
        echo -e "${CYAN}- Creating BIOS Boot partition (512MB)${NC}"
        parted /dev/$disk mkpart primary ext4 1MB 513MB --script
        parted /dev/$disk set 1 boot on --script
        
        echo -e "${CYAN}- Creating Root partition (remaining space)${NC}"
        parted /dev/$disk mkpart primary ext4 513MB 100% --script
    fi
    
    # Wait for kernel to recognize partitions
    sleep 3
    partprobe /dev/$disk
    udevadm settle
    
    # Construct partition device names
    if [[ "$disk" =~ nvme ]]; then
        BOOT_DEV="/dev/${disk}p1"
        ROOT_DEV="/dev/${disk}p2"
    else
        BOOT_DEV="/dev/${disk}1"
        ROOT_DEV="/dev/${disk}2"
    fi
    
    # Format partitions
    echo -e "${CYAN}Formatting partitions...${NC}"
    if [ "$BOOT_MODE" = "EFI" ]; then
        mkfs.fat -F32 "$BOOT_DEV"
    else
        mkfs.ext4 "$BOOT_DEV"
    fi
    mkfs.ext4 "$ROOT_DEV"
    
    # Save mountpoints
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    
    echo -e "${GREEN}✓ Basic partitions created successfully${NC}"
    partition_complete
}

# Create standard partitions on whole disk
create_standard_partitions_wholedisk() {
    local disk=$1
    echo -e "${CYAN}Creating standard partitions on whole disk /dev/${disk}...${NC}"
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
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
        
        echo -e "${CYAN}- Creating Home partition (remaining space)${NC}"
        parted /dev/$disk mkpart primary ext4 31745MB 100% --script
    else
        parted /dev/$disk mklabel msdos --script
        
        echo -e "${CYAN}- Creating BIOS Boot partition (512MB)${NC}"
        parted /dev/$disk mkpart primary ext4 1MB 513MB --script
        parted /dev/$disk set 1 boot on --script
        
        echo -e "${CYAN}- Creating Root partition (30GB)${NC}"
        parted /dev/$disk mkpart primary ext4 513MB 31233MB --script
        
        echo -e "${CYAN}- Creating Home partition (remaining space)${NC}"
        parted /dev/$disk mkpart primary ext4 31233MB 100% --script
    fi
    
    # Wait for kernel to recognize partitions
    sleep 3
    partprobe /dev/$disk
    udevadm settle
    
    # Construct partition device names
    if [[ "$disk" =~ nvme ]]; then
        BOOT_DEV="/dev/${disk}p1"
        ROOT_DEV="/dev/${disk}p2"
        HOME_DEV="/dev/${disk}p3"
    else
        BOOT_DEV="/dev/${disk}1"
        ROOT_DEV="/dev/${disk}2"
        HOME_DEV="/dev/${disk}3"
    fi
    
    # Format partitions
    echo -e "${CYAN}Formatting partitions...${NC}"
    if [ "$BOOT_MODE" = "EFI" ]; then
        mkfs.fat -F32 "$BOOT_DEV"
    else
        mkfs.ext4 "$BOOT_DEV"
    fi
    mkfs.ext4 "$ROOT_DEV"
    mkfs.ext4 "$HOME_DEV"
    
    # Save mountpoints
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    echo "$HOME_DEV -> /home" >> /tmp/asiraos/mounts
    
    echo -e "${GREEN}✓ Standard partitions created successfully${NC}"
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
        "Swap partition" \
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
    if [[ $ADDITIONAL_PARTITIONS == *"Swap partition"* ]]; then
        echo -e "${CYAN}- Creating Swap partition (4GB)${NC}"
        local swap_end=$((next_start + 4096))
        parted /dev/$disk mkpart primary linux-swap ${next_start}MB ${swap_end}MB --script
        next_start=$swap_end
        ((part_num++))
    fi
    
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
    if [[ "$disk" =~ nvme ]]; then
        BOOT_DEV="/dev/${disk}p${current_part}"
    else
        BOOT_DEV="/dev/${disk}${current_part}"
    fi
    
    if [ "$BOOT_MODE" = "EFI" ]; then
        mkfs.fat -F32 "$BOOT_DEV"
    else
        mkfs.ext4 "$BOOT_DEV"
    fi
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    ((current_part++))
    
    # Root partition
    if [[ "$disk" =~ nvme ]]; then
        ROOT_DEV="/dev/${disk}p${current_part}"
    else
        ROOT_DEV="/dev/${disk}${current_part}"
    fi
    mkfs.ext4 "$ROOT_DEV"
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    ((current_part++))
    
    # Additional partitions
    if [[ $ADDITIONAL_PARTITIONS == *"Swap partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            SWAP_DEV="/dev/${disk}p${current_part}"
        else
            SWAP_DEV="/dev/${disk}${current_part}"
        fi
        mkswap "$SWAP_DEV"
        echo "$SWAP_DEV -> swap" >> /tmp/asiraos/mounts
        ((current_part++))
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Var partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            VAR_DEV="/dev/${disk}p${current_part}"
        else
            VAR_DEV="/dev/${disk}${current_part}"
        fi
        mkfs.ext4 "$VAR_DEV"
        echo "$VAR_DEV -> /var" >> /tmp/asiraos/mounts
        ((current_part++))
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Tmp partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            TMP_DEV="/dev/${disk}p${current_part}"
        else
            TMP_DEV="/dev/${disk}${current_part}"
        fi
        mkfs.ext4 "$TMP_DEV"
        echo "$TMP_DEV -> /tmp" >> /tmp/asiraos/mounts
        ((current_part++))
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Home partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            HOME_DEV="/dev/${disk}p${current_part}"
        else
            HOME_DEV="/dev/${disk}${current_part}"
        fi
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
    
    echo -e "${CYAN}Creating basic partitions in free space on /dev/${disk}...${NC}"
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Get real free space information
    FREE_SPACE_INFO=$(get_free_space "/dev/$disk")
    if [ -z "$FREE_SPACE_INFO" ]; then
        gum style --foreground 196 "ERROR: No free space found on /dev/$disk"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    FREE_START=$(echo "$FREE_SPACE_INFO" | awk '{print $1}')
    FREE_SIZE=$(echo "$FREE_SPACE_INFO" | awk '{print $2}')
    
    if [ "$FREE_SIZE" = "0GB" ] || [ "$FREE_SIZE" = "0.00GB" ]; then
        gum style --foreground 196 "ERROR: No usable free space available"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    echo -e "${GREEN}Found free space: $FREE_SIZE starting at $FREE_START${NC}"
    
    # Get next available partition numbers
    LAST_PART=$(parted "/dev/$disk" print 2>/dev/null | awk '/^ *[0-9]/ {last=$1} END {print last}')
    if [ -z "$LAST_PART" ]; then
        BOOT_PART=1
        ROOT_PART=2
    else
        BOOT_PART=$((LAST_PART + 1))
        ROOT_PART=$((LAST_PART + 2))
    fi
    
    echo -e "${GREEN}Will create partitions: $BOOT_PART (boot) and $ROOT_PART (root)${NC}"
    
    # Unmount any existing partitions on this disk
    umount /dev/${disk}* 2>/dev/null || true
    swapoff /dev/${disk}* 2>/dev/null || true
    
    # Create partitions based on boot mode
    if [ "$BOOT_MODE" = "EFI" ]; then
        # Calculate boot partition end (1GB from start)
        BOOT_SIZE_GB=1
        BOOT_END=$(echo "$FREE_START" | sed 's/GB//' | awk -v size="$BOOT_SIZE_GB" '{printf "%.2fGB", $1 + size}')
        
        echo -e "${CYAN}Creating EFI boot partition: $FREE_START to $BOOT_END${NC}"
        parted "/dev/$disk" mkpart primary fat32 "$FREE_START" "$BOOT_END" --script
        parted "/dev/$disk" set "$BOOT_PART" boot on --script
        
        echo -e "${CYAN}Creating root partition: $BOOT_END to end of free space${NC}"
        parted "/dev/$disk" mkpart primary ext4 "$BOOT_END" "100%" --script
    else
        # BIOS mode - 512MB boot partition
        BOOT_SIZE_GB=0.5
        BOOT_END=$(echo "$FREE_START" | sed 's/GB//' | awk -v size="$BOOT_SIZE_GB" '{printf "%.2fGB", $1 + size}')
        
        echo -e "${CYAN}Creating BIOS boot partition: $FREE_START to $BOOT_END${NC}"
        parted "/dev/$disk" mkpart primary ext4 "$FREE_START" "$BOOT_END" --script
        parted "/dev/$disk" set "$BOOT_PART" boot on --script
        
        echo -e "${CYAN}Creating root partition: $BOOT_END to end of free space${NC}"
        parted "/dev/$disk" mkpart primary ext4 "$BOOT_END" "100%" --script
    fi
    
    # Wait for kernel to recognize new partitions
    echo -e "${CYAN}Waiting for system to recognize new partitions...${NC}"
    sleep 3
    partprobe "/dev/$disk"
    udevadm settle
    sleep 2
    
    # Construct partition device names
    if [[ "$disk" =~ nvme ]]; then
        BOOT_DEV="/dev/${disk}p${BOOT_PART}"
        ROOT_DEV="/dev/${disk}p${ROOT_PART}"
    else
        BOOT_DEV="/dev/${disk}${BOOT_PART}"
        ROOT_DEV="/dev/${disk}${ROOT_PART}"
    fi
    
    # Verify partitions were created
    if [ ! -b "$BOOT_DEV" ]; then
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
    else
        echo -e "${GREEN}Formatting $BOOT_DEV as ext4...${NC}"
        mkfs.ext4 "$BOOT_DEV"
    fi
    
    echo -e "${GREEN}Formatting $ROOT_DEV as ext4...${NC}"
    mkfs.ext4 "$ROOT_DEV"
    
    # Save mountpoints
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    
    echo -e "${GREEN}✓ Basic partitions created successfully in free space${NC}"
    echo -e "${GREEN}Boot: $BOOT_DEV -> $BOOT_MOUNTPOINT${NC}"
    echo -e "${GREEN}Root: $ROOT_DEV -> /${NC}"
    
    partition_complete
}

# Create standard partitions in free space - FIXED VERSION
create_standard_partitions_freespace() {
    local disk=$1
    echo -e "${CYAN}Creating standard partitions in free space on /dev/${disk}...${NC}"
    
    # Clear existing mounts
    rm -f /tmp/asiraos/mounts
    mkdir -p /tmp/asiraos
    
    # Get real free space information
    FREE_SPACE_INFO=$(get_free_space "/dev/$disk")
    if [ -z "$FREE_SPACE_INFO" ]; then
        gum style --foreground 196 "ERROR: No free space found"
        gum input --placeholder "Press Enter to continue..."
        disk_selection
        return
    fi
    
    FREE_START=$(echo "$FREE_SPACE_INFO" | awk '{print $1}')
    FREE_SIZE=$(echo "$FREE_SPACE_INFO" | awk '{print $2}')
    
    # Get next available partition numbers
    LAST_PART=$(parted "/dev/$disk" print 2>/dev/null | awk '/^ *[0-9]/ {last=$1} END {print last}')
    if [ -z "$LAST_PART" ]; then
        BOOT_PART=1
        ROOT_PART=2
        HOME_PART=3
    else
        BOOT_PART=$((LAST_PART + 1))
        ROOT_PART=$((LAST_PART + 2))
        HOME_PART=$((LAST_PART + 3))
    fi
    
    # Create partitions
    if [ "$BOOT_MODE" = "EFI" ]; then
        BOOT_END=$(echo "$FREE_START" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 1}')
        ROOT_END=$(echo "$BOOT_END" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 30}')
        
        parted "/dev/$disk" mkpart primary fat32 "$FREE_START" "$BOOT_END" --script
        parted "/dev/$disk" set "$BOOT_PART" boot on --script
        parted "/dev/$disk" mkpart primary ext4 "$BOOT_END" "$ROOT_END" --script
        parted "/dev/$disk" mkpart primary ext4 "$ROOT_END" "100%" --script
    else
        BOOT_END=$(echo "$FREE_START" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 0.5}')
        ROOT_END=$(echo "$BOOT_END" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 30}')
        
        parted "/dev/$disk" mkpart primary ext4 "$FREE_START" "$BOOT_END" --script
        parted "/dev/$disk" set "$BOOT_PART" boot on --script
        parted "/dev/$disk" mkpart primary ext4 "$BOOT_END" "$ROOT_END" --script
        parted "/dev/$disk" mkpart primary ext4 "$ROOT_END" "100%" --script
    fi
    
    # Wait for kernel recognition
    sleep 3
    partprobe "/dev/$disk"
    udevadm settle
    
    # Construct device names
    if [[ "$disk" =~ nvme ]]; then
        BOOT_DEV="/dev/${disk}p${BOOT_PART}"
        ROOT_DEV="/dev/${disk}p${ROOT_PART}"
        HOME_DEV="/dev/${disk}p${HOME_PART}"
    else
        BOOT_DEV="/dev/${disk}${BOOT_PART}"
        ROOT_DEV="/dev/${disk}${ROOT_PART}"
        HOME_DEV="/dev/${disk}${HOME_PART}"
    fi
    
    # Format partitions
    if [ "$BOOT_MODE" = "EFI" ]; then
        mkfs.fat -F32 "$BOOT_DEV"
    else
        mkfs.ext4 "$BOOT_DEV"
    fi
    mkfs.ext4 "$ROOT_DEV"
    mkfs.ext4 "$HOME_DEV"
    
    # Save mountpoints
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
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
        "Swap partition" \
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
    LAST_PART=$(parted "/dev/$disk" print 2>/dev/null | awk '/^ *[0-9]/ {last=$1} END {print last}')
    if [ -z "$LAST_PART" ]; then
        PART_NUM=1
    else
        PART_NUM=$((LAST_PART + 1))
    fi
    
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
    if [[ $ADDITIONAL_PARTITIONS == *"Swap partition"* ]]; then
        SWAP_END=$(echo "$CURRENT_END" | sed 's/GB//' | awk '{printf "%.2fGB", $1 + 4}')
        parted "/dev/$disk" mkpart primary linux-swap "$CURRENT_END" "$SWAP_END" --script
        SWAP_PART=$PART_NUM
        ((PART_NUM++))
        CURRENT_END=$SWAP_END
    fi
    
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
    if [[ "$disk" =~ nvme ]]; then
        BOOT_DEV="/dev/${disk}p${BOOT_PART}"
        ROOT_DEV="/dev/${disk}p${ROOT_PART}"
    else
        BOOT_DEV="/dev/${disk}${BOOT_PART}"
        ROOT_DEV="/dev/${disk}${ROOT_PART}"
    fi
    
    # Format boot and root
    if [ "$BOOT_MODE" = "EFI" ]; then
        mkfs.fat -F32 "$BOOT_DEV"
    else
        mkfs.ext4 "$BOOT_DEV"
    fi
    mkfs.ext4 "$ROOT_DEV"
    
    echo "$BOOT_DEV -> $BOOT_MOUNTPOINT" >> /tmp/asiraos/mounts
    echo "$ROOT_DEV -> /" >> /tmp/asiraos/mounts
    
    # Format additional partitions
    if [[ $ADDITIONAL_PARTITIONS == *"Swap partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            SWAP_DEV="/dev/${disk}p${SWAP_PART}"
        else
            SWAP_DEV="/dev/${disk}${SWAP_PART}"
        fi
        mkswap "$SWAP_DEV"
        echo "$SWAP_DEV -> swap" >> /tmp/asiraos/mounts
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Var partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            VAR_DEV="/dev/${disk}p${VAR_PART}"
        else
            VAR_DEV="/dev/${disk}${VAR_PART}"
        fi
        mkfs.ext4 "$VAR_DEV"
        echo "$VAR_DEV -> /var" >> /tmp/asiraos/mounts
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Tmp partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            TMP_DEV="/dev/${disk}p${TMP_PART}"
        else
            TMP_DEV="/dev/${disk}${TMP_PART}"
        fi
        mkfs.ext4 "$TMP_DEV"
        echo "$TMP_DEV -> /tmp" >> /tmp/asiraos/mounts
    fi
    
    if [[ $ADDITIONAL_PARTITIONS == *"Home partition"* ]]; then
        if [[ "$disk" =~ nvme ]]; then
            HOME_DEV="/dev/${disk}p${HOME_PART}"
        else
            HOME_DEV="/dev/${disk}${HOME_PART}"
        fi
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
    echo -e "${GREEN}Created mountpoints:${NC}"
    if [ -f "/tmp/asiraos/mounts" ]; then
        cat /tmp/asiraos/mounts
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
            echo -e "${CYAN}Current partition layout:${NC}"
            lsblk
            gum input --placeholder "Press Enter to continue..."
            disk_selection
            ;;
    esac
}
