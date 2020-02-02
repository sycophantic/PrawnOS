#!/bin/sh -xe

# Build fs, image


# This file is part of PrawnOS (http://www.prawnos.com)
# Copyright (c) 2018 Hal Emmerich <hal@halemmerich.com>

# PrawnOS is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2
# as published by the Free Software Foundation.

# PrawnOS is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with PrawnOS.  If not, see <https://www.gnu.org/licenses/>.



#Ensure Sudo
if [ ! $UID = "0" ]
then
    echo "Please run this script with sudo, or as root:"
    echo "sudo $0 $*"
    exit 1
fi

if [ -z "$1" ]
then
    echo "No kernel version supplied"
    exit 1
fi
if [ -z "$2" ]
then
    echo "No debian suite supplied"
    exit 1
fi
if [ -z "$3" ]
then
    echo "No base file system image filename supplied"
    exit 1
fi
KVER=$1
DEBIAN_SUITE=$2
BASE=$3

outmnt=$(mktemp -d -p `pwd`)

outdev=/dev/loop5

install_resources=resources/InstallResources
build_resources=resources/BuildResources

#A hacky way to ensure the loops are properly unmounted and the temp files are properly deleted.
#Without this, a reboot is sometimes required to properly clean the loop devices and ensure a clean build
cleanup() {
  set +e

  umount -l $outmnt > /dev/null 2>&1
  rmdir $outmnt > /dev/null 2>&1
  losetup -d $outdev > /dev/null 2>&1

  set +e

  umount -l $outmnt > /dev/null 2>&1
  rmdir $outmnt > /dev/null 2>&1
  losetup -d $outdev > /dev/null 2>&1
}

trap cleanup INT TERM EXIT

#layout the partitons and write filesystem information
create_image() {
  dd if=/dev/zero of=$1 bs=$3 count=$4 conv=sparse
  parted --script $1 mklabel gpt
  cgpt create $1
  kernel_start=8192
  kernel_size=65536
  cgpt add -i 1 -t kernel -b $kernel_start -s $kernel_size -l Kernel -S 1 -T 5 -P 10 $1
  #Now the main filesystem
  root_start=$(($kernel_start + $kernel_size))
  end=`cgpt show $1 | grep 'Sec GPT table' | awk '{print $1}'`
  root_size=$(($end - $root_start))
  cgpt add -i 2 -t data -b $root_start -s $root_size -l Root $1
  # $root_size is in 512 byte blocks while ext4 uses a block size of 1024 bytes
  losetup -P $2 $1
  mkfs.ext4 -F -b 1024 ${2}p2 $(($root_size / 2))

  # mount the / partition
  mount -o noatime ${2}p2 $5
}

# create a 2GB image with the Chrome OS partition layout
create_image $BASE $outdev 50M 40 $outmnt

# use default debootstrap mirror if none is specified
if [ "$PRAWNOS_DEBOOTSTRAP_MIRROR" = "" ]
then
    PRAWNOS_DEBOOTSTRAP_MIRROR=http://ftp.us.debian.org/debian
fi

# install Debian on it
export DEBIAN_FRONTEND=noninteractive
qemu-debootstrap --arch armhf $DEBIAN_SUITE --include locales,init --keyring=$build_resources/debian-archive-keyring.gpg $outmnt $PRAWNOS_DEBOOTSTRAP_MIRROR
chroot $outmnt passwd -d root


#Place the config files and installer script and give them the proper permissions
echo -n PrawnOS > $outmnt/etc/hostname
cp -R $install_resources/ $outmnt/InstallResources/
# and the icons for the lockscreen and app menu
mkdir $outmnt/InstallResources/icons/
cp $build_resources/logo/icons/icon-small.png $outmnt/InstallResources/icons/
cp $build_resources/logo/icons/ascii/* $outmnt/InstallResources/icons/
cp scripts/InstallScripts/* $outmnt/InstallResources/
cp scripts/InstallScripts/InstallPrawnOS.sh $outmnt/
chmod +x $outmnt/*.sh

#Setup the chroot for apt
#This is what https://wiki.debian.org/EmDebian/CrossDebootstrap suggests
cp /etc/hosts $outmnt/etc/
cp $build_resources/sources.list $outmnt/etc/apt/sources.list
sed -i -e "s/suite/$DEBIAN_SUITE/g" $outmnt/etc/apt/sources.list
if [ "$DEBIAN_SUITE" != "sid" ]
then
    # sid doesn't have updates or security; they're present for all other suites
    cat $build_resources/updates.list >> $outmnt/etc/apt/sources.list
    sed -i -e "s/suite/$DEBIAN_SUITE/g" $outmnt/etc/apt/sources.list
    # sid doesn't have backports; it's present for all other suites
    cp $build_resources/backports.list $outmnt/etc/apt/sources.list.d/
    sed -i -e "s/suite/$DEBIAN_SUITE/g" $outmnt/etc/apt/sources.list.d/backports.list
    #setup apt pinning
    cp $build_resources/backports.pref $outmnt/etc/apt/preferences.d/
    sed -i -e "s/suite/$DEBIAN_SUITE/g" $outmnt/etc/apt/preferences.d/backports.pref
    # Install sid (unstable) as an additional source for bleeding edge packages.
    cp $build_resources/sid.list $outmnt/etc/apt/sources.list.d/
    #setup apt pinning
    cp $build_resources/sid.pref $outmnt/etc/apt/preferences.d/
fi
if [ "$DEBIAN_SUITE" = "buster" ]
then
    # Install bullseye (testing) as an additional source
    cp $build_resources/bullseye.list $outmnt/etc/apt/sources.list.d/
    #setup apt pinning
    cp $build_resources/bullseye.pref $outmnt/etc/apt/preferences.d/
fi

#Setup the locale
cp $build_resources/locale.gen $outmnt/etc/locale.gen
chroot $outmnt locale-gen

#Install the base packages
chroot $outmnt apt update
chroot $outmnt apt install -y udev kmod net-tools inetutils-ping traceroute iproute2 isc-dhcp-client wpasupplicant iw alsa-utils cgpt vim-tiny less psmisc netcat-openbsd ca-certificates bzip2 xz-utils ifupdown nano apt-utils git kpartx gdisk parted rsync busybox-static cryptsetup bash-completion libnss-systemd libpam-cap nftables uuid-runtime libgpg-error-l10n libatm1 laptop-detect e2fsprogs-l10n

#add the live-boot fstab
cp -f $build_resources/external_fstab $outmnt/etc/fstab
chmod 644 /etc/fstab

#Cleanup to reduce install size
chroot $outmnt apt-get autoremove --purge
chroot $outmnt apt-get clean

#Download support for libinput-gestures
chroot $outmnt apt install -y libinput-tools xdotool build-essential
#Package is copied into /InstallResources/packages

chroot $outmnt apt-get install -y -t testing -d xsecurelock

#Download the packages to be installed by Install.sh:
chroot $outmnt apt-get install -y -d xorg acpi-support lightdm tasksel dpkg librsvg2-common xorg xserver-xorg-input-libinput alsa-utils anacron avahi-daemon eject iw libnss-mdns xdg-utils lxqt crda xfce4 dbus-user-session system-config-printer tango-icon-theme xfce4-power-manager xfce4-terminal xfce4-goodies mousepad vlc libutempter0 xterm numix-gtk-theme dconf-cli dconf-editor plank network-manager-gnome network-manager-openvpn network-manager-openvpn-gnome dtrx emacs accountsservice sudo pavucontrol-qt papirus-icon-theme sysfsutils bluetooth

chroot $outmnt apt-get install -d -y firefox-esr
# grab chromium as well, since sound is still broken in firefox for some media
chroot $outmnt apt-get install -d -y firmware-ralink

#Cleanup hosts
rm -rf $outmnt/etc/hosts #This is what https://wiki.debian.org/EmDebian/CrossDebootstrap suggests
echo -n "127.0.0.1        PrawnOS" > $outmnt/etc/hosts

umount -l $outmnt > /dev/null 2>&1
rmdir $outmnt > /dev/null 2>&1
losetup -d $outdev > /dev/null 2>&1
echo "DONE!"
trap - INT TERM EXIT
