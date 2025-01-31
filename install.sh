#!/bin/bash
set -e  # Detiene el script ante cualquier error

# --- CONFIGURACIÓN INTERACTIVA ---
clear
echo "═══════════════════════════════════════════════════"
echo "        INSTALADOR DE ARCH LINUX - EQUIPOS LENTOS"
echo "═══════════════════════════════════════════════════"

# Selección del disco
DISKS=$(lsblk -dno NAME,SIZE | grep -Ev 'boot|rpmb|loop' | awk '{print "/dev/"$1,$2}')
DISK=$(echo "$DISKS" | fzf --prompt "Selecciona el disco a formatear: " | awk '{print $1}')
[[ -z "$DISK" ]] && exit 1

read -p "⚠️ ¿Formatear TODOS los datos de $DISK? (y/N): " confirm
[[ $confirm != "y" ]] && exit 1

# Detección BIOS/UEFI
[[ -d /sys/firmware/efi ]] && BOOT_MODE="uefi" || BOOT_MODE="bios"

# Configuración de usuario
read -p "Ingrese nombre de usuario (default: javier): " USERNAME
USERNAME=${USERNAME:-javier}
read -s -p "Ingrese contraseña para $USERNAME: " PASSWORD
echo

# --- PARTICIONADO ---
echo "⌛ Particionando $DISK..."
parted -s $DISK mklabel gpt
if [[ $BOOT_MODE == "uefi" ]]; then
    parted -s $DISK mkpart primary fat32 1MiB 551MiB
    parted -s $DISK set 1 esp on
    EFI_PART="${DISK}1"
else
    parted -s $DISK mkpart primary ext4 1MiB 551MiB
    parted -s $DISK set 1 boot on
    BIOS_PART="${DISK}1"
fi

parted -s $DISK mkpart primary ext4 551MiB -2GiB
ROOT_PART="${DISK}2"

parted -s $DISK mkpart primary linux-swap -2GiB 100%
SWAP_PART="${DISK}3"

# --- FORMATEO ---
echo "⌛ Formateando particiones..."
if [[ $BOOT_MODE == "uefi" ]]; then
    mkfs.fat -F32 $EFI_PART
else
    mkfs.ext4 $BIOS_PART
fi

mkfs.ext4 $ROOT_PART
mkswap $SWAP_PART
swapon $SWAP_PART

# --- MONTAJE ---
mount $ROOT_PART /mnt
[[ $BOOT_MODE == "uefi" ]] && mkdir -p /mnt/boot/efi && mount $EFI_PART /mnt/boot/efi
[[ $BOOT_MODE == "bios" ]] && mkdir -p /mnt/boot && mount $BIOS_PART /mnt/boot

# --- INSTALACIÓN BASE ---
echo "⌛ Instalando sistema base..."
pacstrap /mnt base base-devel linux-lts linux-firmware nano sudo dhcpcd networkmanager iwd wpa_supplicant

# --- CONFIGURACIÓN DEL SISTEMA ---
genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt <<- EOF
    # Configuración regional
    ln -sf /usr/share/zoneinfo/America/Argentina/Buenos_Aires /etc/localtime
    hwclock --systohc
    sed -i 's/#es_AR.UTF-8 UTF-8/es_AR.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    echo "LANG=es_AR.UTF-8" > /etc/locale.conf
    echo "KEYMAP=la-latam" > /etc/vconsole.conf
    
    # Red y hostname
    echo "arch-javier" > /etc/hostname
    echo "127.0.0.1 localhost" >> /etc/hosts
    systemctl enable NetworkManager iwd
    
    # Usuario y contraseña
    useradd -m -G wheel,power,storage,users -s /bin/bash "$USERNAME"
    echo "$USERNAME:$PASSWORD" | chpasswd
    sed -i '/%wheel ALL=(ALL) ALL/s/^# //g' /etc/sudoers
    
    # Drivers gráficos
    lspci | grep -i vga | grep -iq intel && pacman -S --noconfirm xf86-video-intel
    lspci | grep -i vga | grep -iq amd && pacman -S --noconfirm xf86-video-amdgpu
    pacman -S --noconfirm xorg xorg-xinit mesa
    
    # Entorno gráfico
    pacman -S --noconfirm lxqt sddm ttf-dejavu ttf-liberation
    systemctl enable sddm
    
    # Configuración de teclado en X11
    mkdir -p /etc/X11/xorg.conf.d
    echo 'Section "InputClass"
        Identifier "teclado-latam"
        MatchIsKeyboard "on"
        Option "XkbLayout" "latam"
        Option "XkbModel" "pc105"
    EndSection' > /etc/X11/xorg.conf.d/00-keyboard.conf
    
    # Aplicaciones
    pacman -S --noconfirm firefox libreoffice-still remmina
    
    # Acceso remoto
    pacman -S --noconfirm xrdp tightvncserver
    echo "[xrdp]
    name=XRDP
    exec=startlxqt" > /etc/xrdp/sesman.ini
    systemctl enable xrdp
    
    # Optimizaciones
    pacman -S --noconfirm zram-generator
    echo "[zram0]
    zram-size = min(ram / 2, 4096)" > /etc/systemd/zram-generator.conf
    systemctl start systemd-zram-setup@zram0
    
    # Red
    echo "net.core.rmem_max=16777216" >> /etc/sysctl.d/network.conf
    echo "net.core.wmem_max=16777216" >> /etc/sysctl.d/network.conf
EOF

# --- POST-INSTALACIÓN ---
echo "✅ Instalación completada! Ejecuta estos comandos:"
echo "   umount -R /mnt"
echo "   reboot"