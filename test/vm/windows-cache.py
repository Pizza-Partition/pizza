"""Content-bound, portable Windows baseline cache; never cache test overlays."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


FILES = ("windows.qcow2", "OVMF_CODE.fd", "OVMF_VARS.fd", "baseline.json")


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def key(inputs):
    return "windows-base-v1-" + hashlib.sha256(
        json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def image():
    config = json.loads(Path("test/windows-vm/images.json").read_text())
    return next(x for x in config["images"] if x["id"] == config["default_image"])


def inputs(stage):
    selected = image()
    return {
        "schema": 1,
        "image": {x: selected[x] for x in ("id", "sha256", "size")},
        "guest_sha256": digest(stage / "windows-vm-guest.exe"),
        "recipe": {p: digest(p) for p in (
            "test/windows-vm/provision.zig", "test/windows-vm/autounattend.xml",
            "test/windows-vm/cpu.zig",
            "test/windows-vm/vm.zig", "test/windows-vm/libvirt.zig",
            "test/windows-vm/virtio.json", "test/vm/common.zig",
        )},
        "runtime": subprocess.check_output([
            "pacman", "-Q", "qemu-system-x86", "qemu-img", "edk2-ovmf", "libvirt"
        ], text=True),
        "firmware": {name: digest(Path("/usr/share/edk2/x64") / name) for name in (
            "OVMF_CODE.4m.fd", "OVMF_VARS.4m.fd"
        )},
    }


def require_baseline(base, expected):
    record = json.loads((base / "baseline.json").read_text())
    if not (record.get("status") == "ready" and record.get("transport") == "agent"
            and record.get("updates_disabled") is True
            and record.get("guest_sha256") == expected["guest_sha256"]
            and record.get("image", {}).get("sha256") == expected["image"]["sha256"]):
        raise ValueError("Baseline is not frozen or does not match its inputs")


def pack(base, cache, expected):
    require_baseline(base, expected)
    for name in ("windows.raw", "OVMF_CODE.fd", "OVMF_VARS.fd"):
        p = base / name
        if p.is_symlink() or p.stat().st_mode & 0o222:
            raise ValueError("Only an immutable baseline can be cached")
    cache.mkdir(parents=True, exist_ok=False)
    # A standalone compressed qcow2 avoids expanding a sparse raw disk in the
    # Actions tar archive or consuming the full virtual disk size on restore.
    subprocess.run(["qemu-img", "convert", "-f", "raw", "-O", "qcow2", "-c",
                    "-o", "compression_type=zstd",
                    str(base / "windows.raw"), str(cache / "windows.qcow2")], check=True)
    for name in FILES[1:]:
        shutil.copyfile(base / name, cache / name)
    manifest = {"key": key(expected), "inputs": expected, "files": {
        name: {"sha256": digest(cache / name), "size": (cache / name).stat().st_size}
        for name in FILES
    }}
    (cache / "manifest.json").write_text(json.dumps(manifest, indent=2))


def restore(cache, base, expected):
    manifest = json.loads((cache / "manifest.json").read_text())
    if manifest.get("key") != key(expected) or manifest.get("inputs") != expected:
        raise ValueError("Cached baseline inputs do not match this build")
    if set(manifest.get("files", {})) != set(FILES):
        raise ValueError("Incomplete cached baseline")
    for name in FILES:
        p = cache / name
        if p.is_symlink() or not p.is_file():
            raise ValueError("Invalid cached baseline file")
        if manifest["files"][name] != {"sha256": digest(p), "size": p.stat().st_size}:
            raise ValueError("Cached baseline checksum mismatch: " + name)
    require_baseline(cache, expected)
    info = json.loads(subprocess.check_output([
        "qemu-img", "info", "--output=json", "-f", "qcow2", str(cache / "windows.qcow2")
    ]))
    if info.get("backing-filename") or info["virtual-size"] > 256 * 1024**3:
        raise ValueError("Cached disk is not a standalone bounded baseline")
    base.mkdir(parents=True, exist_ok=False)
    try:
        subprocess.run(["qemu-img", "convert", "-f", "qcow2", "-O", "raw",
                        str(cache / "windows.qcow2"), str(base / "windows.raw")], check=True)
        for name in FILES[1:]:
            shutil.copyfile(cache / name, base / name)
        for name in ("windows.raw", "OVMF_CODE.fd", "OVMF_VARS.fd"):
            (base / name).chmod(0o444)
    except BaseException:
        shutil.rmtree(base)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inputs", "pack", "restore"))
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--stage", type=Path)
    parser.add_argument("--base", type=Path)
    parser.add_argument("--cache", type=Path)
    args = parser.parse_args()
    if args.action == "inputs":
        value = inputs(args.stage)
        args.inputs.write_text(json.dumps(value, indent=2))
        selected = image()
        print("baseline-key=" + key(value))
        print("iso-key=windows-iso-v1-" + selected["sha256"] + "-" + str(selected["size"]))
        print("iso-path=.zig-cache/windows-e2e/images/" + selected["filename"])
    else:
        expected = json.loads(args.inputs.read_text())
        if args.action == "pack":
            pack(args.base, args.cache, expected)
        else:
            restore(args.cache, args.base, expected)


if __name__ == "__main__":
    main()
