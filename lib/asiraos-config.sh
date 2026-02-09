#!/bin/bash


set -euo pipefail

# AsiraOS System Configuration Script
# Configures OS branding, repositories, and GRUB theme

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

configure_asiraos_system() {
  local grub_theme_dir="${1:-}"
  
  log "Configuring AsiraOS system branding..."
  
  # Install reflector for mirror management
  
  # Create new os-release content
  cat > /etc/os-release << 'EOF'
NAME="AsiraOS"
PRETTY_NAME="AsiraOS"
ID=asiraos
BUILD_ID=rolling
ANSI_COLOR="38;2;220;50;47"
HOME_URL="https://github.com/asiraos"
SUPPORT_URL="https://github.com/asiraos"
BUG_REPORT_URL="https://github.com/asiraos"
LOGO=asiraos
IMAGE_ID=asiraos
IMAGE_VERSION=2025.05.11
EOF
  
  # Add AsiraOS repository (Arch-based systems only)

  curl -sSl https://asiraos.github.io/core/asiraos-core.pubkey.asc | sudo pacman-key --add -
  if command -v pacman >/dev/null 2>&1; then
    if ! grep -q "\[asiraos-core\]" /etc/pacman.conf; then
      sed -i '/^\[core\]/i \
[asiraos-core]\nSigLevel = Optional TrustAll\nServer = https://asiraos.github.io/core/$arch\n' /etc/pacman.conf
    fi
  fi
  
  # Configure GRUB theme script
  cat > /etc/grub.d/05_asiraos_theme << 'EOF'
#!/bin/bash

# Use the logo from the installer lib directory
LOGO_SOURCE="/boot/grub/themes/shared/asiraos.png"
GRUB_THEMES_DIR="/boot/grub/themes"

if [[ ! -f "$LOGO_SOURCE" ]]; then
    echo "Logo not found at $LOGO_SOURCE"
    exit 1
fi

# Create shared directory and copy logo
mkdir -p "/boot/grub/themes/shared"
cp "$LOGO_SOURCE" "/boot/grub/themes/shared/asiraos.png"

# Copy logo to all existing theme directories
for theme_dir in ${GRUB_THEMES_DIR}/*/; do
    [[ "$theme_dir" == *"/shared/" ]] && continue
    mkdir -p "${theme_dir}icons"
    cp "$LOGO_SOURCE" "${theme_dir}icons/asiraos.png"
done

echo "Logo copied to all GRUB themes."
EOF

  chmod +x /etc/grub.d/05_asiraos_theme
  
  # Update GRUB branding and OS detection
  sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="AsiraOS"/' /etc/default/grub || \
    echo 'GRUB_DISTRIBUTOR="AsiraOS"' >> /etc/default/grub
  
  # Override lsb-release for proper OS detection
  cat > /etc/lsb-release << 'EOF'
DISTRIB_ID=AsiraOS
DISTRIB_RELEASE=rolling
DISTRIB_CODENAME=rolling
DISTRIB_DESCRIPTION="AsiraOS"
EOF
  
  # Set GRUB theme if provided
  if [[ -n "$grub_theme_dir" ]]; then
    sed -i "s|^#*GRUB_THEME=.*|GRUB_THEME=\"$grub_theme_dir/theme.txt\"|" /etc/default/grub
  fi
  
  # Regenerate GRUB config (works on both Debian and Arch)
  if command -v update-grub >/dev/null 2>&1; then
    update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg
  fi
  
  log "AsiraOS system configuration completed"
}

# Run the function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  configure_asiraos_system "$@"
fi
