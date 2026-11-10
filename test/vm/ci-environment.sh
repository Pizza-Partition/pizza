#!/usr/bin/env bash
set -euo pipefail

# Runs only in the disposable Arch CI container, never on the user's host.
[[ -f /etc/arch-release && $(id -u) == 0 ]]
printf 'Server = https://archive.archlinux.org/repos/2026/10/30/$repo/os/$arch\n' > /etc/pacman.d/mirrorlist
pacman -Syyuu --noconfirm --needed archlinux-keyring git python python-pefile \
  curl binutils libarchive pkgconf gcc glib2 systemd systemd-ukify \
  libblockdev libblockdev-fs libblockdev-part libblockdev-swap \
  e2fsprogs dosfstools mtools util-linux parted kmod cpio \
  linux mkinitcpio qemu-system-x86 qemu-img edk2-ovmf libvirt dmidecode
pacman -Q > .zig-cache/ci-vm-packages.txt
chmod a+rw /dev/kvm
useradd --create-home --uid "$PIZZA_CI_UID" pizza-ci
chown -R pizza-ci:pizza-ci "$PWD" "$RUNNER_TEMP"
exec runuser -u pizza-ci -- bash test/vm/ci.sh "$@"
