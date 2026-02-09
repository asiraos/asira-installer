#!/bin/bash

USER=$(ls -1 /home)
DOTFILES="/tmp/asira-hypr-dots"

# Hyprland Desktop Environment Installation
echo "Installing Hyprland Desktop Environment..."

pacman -S --noconfirm --needed hyprland waybar wofi kitty sddm git
systemctl enable sddm

install_grubthemes() {
  sudo mkdir -p /boot/grub/themes/
  sudo cp -rf $DOTFILES/rootfiles/grub/Castorice /boot/grub/themes/
  sudo sed -i '/^GRUB_THEME=/d' /etc/default/grub && echo 'GRUB_THEME="/boot/grub/themes/Castorice/theme.txt"' | sudo tee -a /etc/default/grub
  sudo grub-mkconfig -o /boot/grub/grub.cfg
}
install_grubthemes

git clone https://github.com/aislxflames/flamedots $DOTFILES
sudo pacman -S --needed --noconfirm $(grep -vE '^\s*#|^\s*$' $DOTFILES/packages.sh)
mkdir -p /home/$USER
chown -R $USER:$USER /home/$USER

cp -r $DOTFILES/dotfiles/. /etc/skel/
cp -r $DOTFILES/dotfiles/. /home/$USER/

sed -i '/^bind = $mainMod, g, hyprexpo:expo,toggle/s/^/#/' /home/$USER/.config/hypr/conf/keybinds/default.conf
sed -i '/plugin/ s/^[[:space:]]*/# /' /home/$USER/.config/hypr/hyprland.conf
sed -i '/^bind = $mainMod, g, hyprexpo:expo,toggle/s/^/#/' /home/$USER/.config/hypr/conf/keybinds/default.conf
sed -i '/plugin/ s/^[[:space:]]*/# /' /home/$USER/.config/hypr/hyprland.conf

mkdir -p /home/$USER/flamedots
cp -r $DOTFILES/. /home/$USER/flamedots/
cat << 'EOF' > /home/$USER/post-setup.sh
  kitty -e ~/flamedots/scripts/asira-setup.sh
EOF
chown -R $USER:$USER /home/$USER/post-setup.sh
chmod +x /home/$USER/post-setup.sh

echo "exec-once = /home/$USER/post-setup.sh" >> /home/$USER/.config/hypr/hyprland.conf

echo "Hyprland installation completed"
