"""Fetch only three checksum-locked driver files from the official VirtIO ISO."""
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

lock = json.loads((Path(__file__).resolve().parents[1] / "windows-vm/virtio.json").read_text())
out = Path(sys.argv[1]) / "vioscsi"
out.mkdir(parents=True, exist_ok=True)
for item in lock["files"]:
    start, size = item["offset"], item["size"]
    request = urllib.request.Request(
        lock["url"] + f"?range={start}",
        headers={"Range": f"bytes={start}-{start + size - 1}"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        if response.status != 206 or not response.headers.get("Content-Range", "").startswith(f"bytes {start}-{start + size - 1}/"):
            raise SystemExit("VirtIO server did not honor the requested file range")
        data = response.read(size + 1)
    if len(data) != size or hashlib.sha256(data).hexdigest() != item["sha256"]:
        raise SystemExit(f"VirtIO checksum mismatch: {item['name']}")
    (out / item["name"]).write_bytes(data)
    print(f"Verified {item['name']}")
