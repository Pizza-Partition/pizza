"""Install the repository's checksum-locked Linux Zig toolchain for VM CI."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import urllib.request

root = Path(__file__).resolve().parents[2]
lock = json.loads((root / "config/toolchain.json").read_text())
source = lock["x86_64-linux"]
out = Path(os.environ["RUNNER_TEMP"]) / "pizza-zig"
out.mkdir(parents=True, exist_ok=True)
archive = out / "zig.tar.xz"
def checksum(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


if not archive.is_file() or checksum(archive) != source["sha256"]:
    with urllib.request.urlopen(source["url"], timeout=120) as response, archive.open("wb") as dest:
        while chunk := response.read(1024 * 1024):
            dest.write(chunk)
if checksum(archive) != source["sha256"]:
    raise SystemExit("Zig archive SHA-256 mismatch")
with tarfile.open(archive) as package:
    package.extractall(out, filter="data")
zig = out / f"zig-x86_64-linux-{lock['version']}" / "zig"
if subprocess.check_output([zig, "version"], text=True).strip() != lock["version"]:
    raise SystemExit("Zig version mismatch")
print(zig)
