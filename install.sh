#!/bin/bash
set -e

# --- CONFIGURACIÓN INTERACTIVA ---
clear
echo "═══════════════════════════════════════════════════"
echo "   INSTALADOR ARCH LINUX - EQUIPOS DE BAJOS RECURSOS"
echo "═══════════════════════════════════════════════════"

# --- VERIFICAR CONEXIÓN A INTERNET ---
check_network() {
    if ! ping -c 3 archlinux.org &> /dev/null; then
        echo "❌ Error: No hay conexión a Internet."
        echo "Configura la red manualmente con:"
        echo "1. iwctl"
        echo "2. dhcpcd"
        exit 1
    fi
}
check_network

# --- SELECCIÓN DE DISCO ---
select_disk() {
    echo "Discos disponibles:"
    lsblk -dno NAME,SIZE,PATH | grep -Ev 'boot|rpmb|loop'
    read -p "Ingresa el nombre del disco (ej: sda/nvme0n1): " DISK
    DISK="/dev/${DISK}"
    
    if [[ ! -b $DISK ]]; then
        echo "❌ Disco no válido!"
        exit 1
    fi

    read -p "⚠️ ¿Formatear TODOS los datos de $DISK? (y/N): " confirm
    [[ $confirm != "y" ]] && exit 1
}

select_disk

# --- DETECCIÓN BIOS/UEFI ---
[[ -d /sys/firmware/efi ]] && BOOT_MODE="uefi" || BOOT_MODE="bios"

# --- CONFIGURACIÓN DE USUARIO ---
read -p "Nombre de usuario (default: javier): " USERNAME
USERNAME=${USERNAME:-javier}
read -s -p "Contraseña para $USERNAME: " PASSWORD
echo

# --- PARTICIONADO ---
parted -s $DISK mklabel gpt

if [[ $BOOT_MODE == "uefi" ]]; then
    parted -s $DISK mkpart ESP fat32 1MiB 551MiB
    parted -s $DISK set 1 esp on
    EFI_PART="${DISK}p1"
else
    parted -s $DISK mkpart BIOS ext4 1MiB 551MiB
    parted -s $DISK set 1 boot on
    BIOS_PART="${DISK}1"
fi

parted -s $DISK mkpart ROOT ext4 551MiB -4GiB
ROOT_PART="${DISK}2"

parted -s $DISK mkpart SWAP linux-swap -4GiB 100%
SWAP_PART="${DISK}3"

# --- FORMATEO Y MONTAJE ---
mkfs.ext4 $ROOT_PART
mkswap $SWAP_PART
swapon $SWAP_PART

if [[ $BOOT_MODE == "uefi" ]]; then
    mkfs.fat -F32 $EFI_PART
else
    mkfs.ext4 $BIOS_PART
fi

mount $ROOT_PART /mnt

if [[ $BOOT_MODE == "uefi" ]]; then
    mkdir -p /mnt/boot/efi
    mount $EFI_PART /mnt/boot/efi
else
    mkdir -p /mnt/boot
    mount $BIOS_PART /mnt/boot
fi

# --- INSTALACIÓN BASE ---
pacstrap /mnt base base-devel linux-lts linux-firmware \
          nano sudo networkmanager grub efibootmgr \
          dosfstools os-prober mtools

# --- CONFIGURACIÓN DEL SISTEMA ---
genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
# Configuración básica
ln -sf /usr/share/zoneinfo/America/Argentina/Buenos_Aires /etc/localtime
hwclock --systohc

sed -i 's/#es_AR.UTF-8/es_AR.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=es_AR.UTF-8" > /etc/locale.conf
echo "KEYMAP=la-latam" > /etc/vconsole.conf

# Red y hostname
echo "arch-javier" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
systemctl enable NetworkManager

# Usuario y privilegios
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Bootloader
if [[ "$BOOT_MODE" == "uefi" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH
else
    grub-install --target=i386-pc $DISK
fi
grub-mkconfig -o /boot/grub/grub.cfg

# Entorno gráfico
pacman -S --noconfirm xorg lxqt sddm \
          firefox libreoffice-still \
          ttf-dejavu ttf-liberation

# Configuración de teclado
mkdir -p /etc/X11/xorg.conf.d
echo 'Section "InputClass"
        Identifier "teclado-latam"
        MatchIsKeyboard "on"
        Option "XkbLayout" "latam"
        Option "XkbModel" "pc105"
EndSection' > /etc/X11/xorg.conf.d/00-keyboard.conf

# Optimizaciones
pacman -S --noconfirm zram-generator
echo "[zram0]" > /etc/systemd/zram-generator.conf
echo "zram-size = min(ram / 2, 4096)" >> /etc/systemd/zram-generator.conf
systemctl enable systemd-zram-setup@zram0

# AUR (como usuario normal)
pacman -S --noconfirm git
sudo -u $USERNAME bash -c 'git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin'
cd /tmp/yay-bin && sudo -u $USERNAME makepkg -si --noconfirm
EOF

# --- POST-INSTALACIÓN ---
echo "✅ Instalación completada! Ejecuta:"
echo "   umount -R /mnt"
echo "   reboot"
