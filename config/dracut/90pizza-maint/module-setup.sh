#!/bin/bash
# Dracut owns this script's execution environment.
check() {
    [[ -f ${PIZZA_MAINT_BINARY:-} && -d ${PIZZA_BUNDLE_ROOT:-} && -d ${PIZZA_PANEL_ROOT:-} ]] || return 1
    return 0
}
depends() { return 0; }
installkernel() {
    local -a drivers
    local driver dependencies action source destination relative unused
    read -r -a drivers <<< "${PIZZA_DRIVERS:-virtio_pci virtio_blk nvme ahci ext4}"
    instmods "${drivers[@]}" || return 1
    mkdir -p "$initdir/etc/pizza" || return 1
    printf '%s\n' "$kernel" > "$initdir/etc/pizza/kernel-version" || return 1
    : > "$initdir/etc/pizza/modules" || return 1
    # Resolve soft and hard dependencies with host kmod at build time. No host
    # modprobe or its shared libraries are needed in the maintenance image.
    for driver in "${drivers[@]}"; do
        dependencies=$(modprobe --dirname "${PIZZA_MODULES_ROOT:-/}" --config /dev/null --ignore-install --set-version "$kernel" --show-depends -- "$driver") || return 1
        while read -r action source unused; do
            [[ $action == insmod ]] || continue # built-ins need no loading
            case "$source" in
                "${PIZZA_MODULES_ROOT:-/}"/lib/modules/"$kernel"/*) relative=${source#"${PIZZA_MODULES_ROOT:-/}"/lib/modules/} ;;
                /lib/modules/"$kernel"/*) relative=${source#/lib/modules/} ;;
                /usr/lib/modules/"$kernel"/*) relative=${source#/usr/lib/modules/} ;;
                *) derror "Unexpected module path: $source"; return 1 ;;
            esac
            destination="/lib/modules/$relative"
            case "$destination" in
                *.zst) destination=${destination%.zst} ;;
                *.xz) destination=${destination%.xz} ;;
                *.gz) destination=${destination%.gz} ;;
            esac
            [[ $destination == *.ko ]] || return 1
            # Decompress before packing so finit_module works with Linux 4.18,
            # without relying on CONFIG_MODULE_DECOMPRESS in the booted kernel.
            mkdir -p "$initdir${destination%/*}" || return 1
            case "$source" in
                *.zst) zstd -dc -- "$source" > "$initdir$destination" || return 1 ;;
                *.xz) xz -dc -- "$source" > "$initdir$destination" || return 1 ;;
                *.gz) gzip -dc -- "$source" > "$initdir$destination" || return 1 ;;
                *) cp -- "$source" "$initdir$destination" || return 1 ;;
            esac
            if [[ $destination != "/lib/modules/$relative" ]]; then
                rm -f -- "$initdir/lib/modules/$relative" "$initdir/usr/lib/modules/$relative"
            fi
            # Preserve the dependency order and list each module only once.
            if ! grep -Fxq -- "$destination" "$initdir/etc/pizza/modules"; then
                printf '%s\n' "$destination" >> "$initdir/etc/pizza/modules" || return 1
            fi
        done <<< "$dependencies"
    done
}
install() {
    # inst_simple avoids dracut resolving any host userspace dependencies.
    inst_simple "$PIZZA_MAINT_BINARY" /init || return 1
    # The builder uses --include after dracut's host dependency scan, so the
    # already-relocated bundle is copied verbatim rather than resolved again.
    mkdir -p "$initdir/proc" "$initdir/sys" "$initdir/dev" "$initdir/run" || return 1
    # Upstream release WPE hardcodes its libexec location. These aliases live
    # only in the RAM image and point into the audited bundle, never a host root.
    mkdir -p "$initdir/usr/lib" "$initdir/usr/share" || return 1
    ln -s /opt/pizza/bundle/lib/wpe-webkit-2.0 "$initdir/usr/lib/wpe-webkit-2.0" || return 1
    ln -s /opt/pizza/bundle/share/wpe-webkit-2.0 "$initdir/usr/share/wpe-webkit-2.0" || return 1
    # core/initramfs/image.zig appends /dev/console in an unprivileged newc archive.
}
