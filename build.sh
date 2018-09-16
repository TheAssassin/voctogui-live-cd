#! /bin/bash

if [ $(id -u) != 0 ]; then
    echo "$(tput setaf 3)$(tput bold)ERROR: this script should run with root permissions, otherwise sudo, networking etc. won't work in the built image$(tput sgr0)"
fi

set -xe

# don't re-download file on every run
wget -c https://ftp.tu-chemnitz.de/pub/linux/ubuntu-cdimage/xubuntu/releases/18.04/release/xubuntu-18.04.1-desktop-amd64.iso
echo "cd4ad5df40a542db9eef2e0449a6c1839c5c14e26053642c4ad39d5026b73b1a *xubuntu-18.04.1-desktop-amd64.iso" | sha256sum -c

# use RAM disk if possible
if [ "$CI" == "" ] && [ -d /dev/shm ]; then
    TEMP_BASE=/dev/shm
else
    TEMP_BASE=/tmp
fi

BUILD_DIR=$(mktemp -d -p "$TEMP_BASE" iso-build-XXXXXX)

cleanup () {
    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
    fi
}

trap cleanup EXIT

# store repo root as variable
REPO_ROOT=$(readlink -f $(dirname $(dirname $0)))
OLD_CWD=$(readlink -f .)

pushd "$BUILD_DIR"

mkdir -p img/
# extract without pre-built root filesystem
# we want the "live ISO" experience only
7z x "$OLD_CWD"/xubuntu-18.04.1-desktop-amd64.iso -oimg/ #-xr"!casper/filesystem*"

# edit ISO image contents
pushd img/

# directly boot to live desktop
sed -i '/ui gfxboot bootlogo/ s/^#*/#/' isolinux/isolinux.cfg
sed -i 's/default vesamenu.c32/default live/g' isolinux/isolinux.cfg

# extract squashfs image to edit it
pushd casper/
unsquashfs -user-xattrs filesystem.squashfs
rm filesystem.squashfs

# don't show Ubuntu installer on boot
rm -r squashfs-root/etc/init/ubiquity*

crt() {
     fakeroot fakechroot $(which chroot) $(readlink -f squashfs-root/) "$@"
}

# remove unused packages to save some space
crt apt-get purge -y 'ubiquity*'

# install voctomix following instructions in README
crt apt-get install -y gstreamer1.0-plugins-bad gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly gstreamer1.0-alsa gstreamer1.0-tools libgstreamer1.0-0 python3 python3-gi python3-gi-cairo gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0 gir1.2-gtk-3.0
git clone https://github.com/voc/voctomix/ -b 1.2 squashfs-root/opt/voctomix

crt cat > squashfs-root/etc/init/voctogui.conf <<EOF
start on (starting gdm
	  or starting kdm
	  or starting xdm
	  or starting lxdm
	  or starting lightdm)
stop on (runlevel [06]
	 or stopping gdm
	 or stopping kdm
	 or stopping xdm
	 or stopping lxdm
	 or stopping lightdm)

task
normal exit 0 1

emits starting-dm

exec python3 /opt/voctomix/voctogui/voctogui.py
EOF

# re-build squashfs image
mksquashfs squashfs-root/ filesystem.squashfs
rm -rf squashfs-root

# back to image root
popd

# re-build ISO
mkisofs -l -D -r -V "Live ISO" -cache-inodes -J -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -o ../voctomix-18.04.1_$(date +%Y-%m-%d).iso .

# back to build directory
popd

mv voctomix*.iso "$OLD_CWD"
