#!/bin/bash

USER=$(ls -1 /home)
DOTFILES="/tmp/asira-hypr-dots"

# Hyprland Desktop Environment Installation
echo "Installing Hyprland Desktop Environment..."

pacman -S --noconfirm --needed hyprland waybar wofi kitty sddm git
systemctl enable sddm
pacman -S --noconfirm --needed < $DOTFILES/packages.sh

install_grubthemes() {
  sudo mkdir -p /boot/grub/themes/
  sudo cp -rf $DOTFILES/rootfiles/grub/Castorice /boot/grub/themes/
  sudo sed -i '/^GRUB_THEME=/d' /etc/default/grub && echo 'GRUB_THEME="/boot/grub/themes/Castorice/theme.txt"' | sudo tee -a /etc/default/grub
  sudo grub-mkconfig -o /boot/grub/grub.cfg
}
install_grubthemes

git clone https://github.com/aislxflames/flamedots $DOTFILES
mkdir -p /home/$USER
chown -R $USER:$USER /home/$USER

cp -r $DOTFILES/dotfiles/. /etc/skel/
cp -r $DOTFILES/dotfiles/. /home/$USER/

cp -r $DOTFILES/scripts/asira-setup.sh /home/$USER/post-setup.sh
chown -R $USER:$USER /home/$USER/post-setup.sh
echo '~/post-setup.sh' >> ~/.bashrc

echo "Hyprland installation completed"
