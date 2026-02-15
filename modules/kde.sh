#!/bin/bash


# KDE Plasma Desktop Environment Installation
echo "Installing KDE Plasma Desktop Environment..."

pacman -S --noconfirm --needed plasma-meta kitty dolphin firefox kde-applications sddm
systemctl enable sddm

echo "KDE Plasma installation completed"
