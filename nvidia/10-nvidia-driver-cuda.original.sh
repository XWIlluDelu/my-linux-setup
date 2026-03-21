#!/usr/bin/env bash

sudo apt -y purge evince evince-common eog
sudo apt -y autoremove --purge
sudo apt -y clean

sudo apt install -y linux-headers-$(uname -r) build-essential dkms git wget curl

wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb

sudo apt-get update
sudo apt-get install -y nvidia-driver-570-open

sudo tee /etc/apt/preferences.d/nvidia-570-pin >/dev/null <<'EOF'
Package: cuda-drivers
Pin: release o=NVIDIA
Pin-Priority: -1

Package: nvidia-open
Pin: release o=NVIDIA
Pin-Priority: -1

Package: cuda-drivers-*
Pin: version 570.*
Pin-Priority: 1001

Package: nvidia-driver-570*
Pin: version 570.*
Pin-Priority: 1001

Package: libnvidia-*
Pin: version 570.*
Pin-Priority: 1001
EOF

sudo apt-get update
sudo apt-mark hold cuda-drivers-570 nvidia-driver-570-open nvidia-driver-570
sudo apt-mark hold 'libnvidia-*'

nvidia-smi

sudo apt-get -y install cuda-toolkit-12-8

sudo apt -y purge evince evince-common eog
sudo apt update
sudo apt -y full-upgrade
sudo apt -y autoremove --purge
sudo apt -y autoclean
sudo apt -y clean
dpkg -l | awk '/^rc/ {print $2}' | xargs -r sudo apt -y purge

sudo reboot

sudo apt update
sudo apt -y full-upgrade
sudo apt -y autoremove --purge
sudo apt -y autoclean
sudo apt -y clean
dpkg -l | awk '/^rc/ {print $2}' | xargs -r sudo apt -y purge
sudo dpkg --configure -a
sudo apt-get install -f
sudo dkms autoinstall
sudo update-initramfs -u
sudo update-grub
sudo reboot

nvidia-smi
