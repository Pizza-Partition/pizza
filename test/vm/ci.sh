#!/usr/bin/env bash
set -euo pipefail

mode=${1:?linux-512, linux-4096 or windows}
out="$PWD/.zig-cache/ci-vm-$mode"
mkdir -p "$out"
[[ -r /dev/kvm && -w /dev/kvm ]]
zig=$(python3 test/vm/install-zig.py)
export ZIG="$zig"

case "$mode" in
  linux-512|linux-4096)
    sector=${mode#linux-}
    "$zig" build stage-linux-tests maintenance-files -j2 -Dheadless=true \
      -Doptimize=safe --prefix "$out/stage" --summary all
    kernels=(/usr/lib/modules/*/vmlinuz)
    [[ ${#kernels[@]} == 1 && -f ${kernels[0]} ]]
    kernel=${kernels[0]}
    release=$(basename "$(dirname "$kernel")")
    cat > "$out/mkinitcpio.conf" <<'CONFIG'
MODULES=(nvme ext4)
BINARIES=()
FILES=()
HOOKS=(base udev modconf block filesystems)
COMPRESSION="zstd"
CONFIG
    mkinitcpio -c "$out/mkinitcpio.conf" -k "$release" -g "$out/initrd.img"
    "$zig" build test-linux-vm -j2 -Dheadless=true -- provision \
      --stage "$out/stage/bin" --maintenance "$out/stage/share/pizza/maintenance" \
      --kernel "$kernel" --kernel-version "$release" --initrd "$out/initrd.img" \
      --ukify /usr/lib/systemd/ukify --out "$out/base"
    "$zig" build test-linux-vm -j2 -Dheadless=true -- run \
      --base "$out/base" --stage "$out/stage/bin" --out "$out/run" \
      --accel kvm --sector "$sector" --timeout 900
    ;;
  windows)
    # The suite and installer both use the basic VGA device, without optional GPU modules.
    qemu-system-x86_64 -device help > "$out/qemu-devices.log"
    grep -F 'name "VGA",' "$out/qemu-devices.log"
    "$zig" build build-windows-vm-artifacts -j2 -Dheadless=true -- --out "$out/artifacts"
    "$zig" build fetch-windows-image -j2 -Dheadless=true
    python3 test/vm/fetch-virtio.py "$out/drivers"
    "$zig" build provision-windows-vm -j2 -Dheadless=true -Dvm-libvirt=/usr -- \
      --stage "$out/artifacts/stage/bin" --drivers "$out/drivers" \
      --out "$out/base" --timeout 3600
    "$zig" build test-windows-vm -j2 -Dheadless=true -Dvm-libvirt=/usr -- \
      --base "$out/base" --stage "$out/artifacts/stage/bin" --out "$out/run" --timeout 900
    ;;
  *) echo "Unknown VM matrix entry: $mode" >&2; exit 2 ;;
esac
python3 test/vm/check-results.py "$out/run/results.json"
