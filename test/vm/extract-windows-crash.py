"""Read crash evidence from a raw GPT test disk without mounting it."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import uuid


def partitions(disk):
    with disk.open("rb") as stream:
        stream.seek(512)
        header = stream.read(512)
        if header[:8] != b"EFI PART":
            raise ValueError("Expected a GPT test disk")
        table, count, size = struct.unpack_from("<QII", header, 72)
        if not 0 < count <= 4096 or not 128 <= size <= 4096:
            raise ValueError("Invalid GPT entry bounds")
        stream.seek(table * 512)
        for index in range(count):
            entry = stream.read(size)
            if str(uuid.UUID(bytes_le=entry[:16])) == "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7":
                yield index + 1, struct.unpack_from("<Q", entry, 32)[0]


class Evidence:
    def __init__(self, disk, offset, out):
        self.disk, self.offset, self.out = disk, offset, out
        self.directory_cache = {}
        self.records = []

    def directory(self, inode=None):
        if inode not in self.directory_cache:
            args = ["fls", "-u", "-p", "-o", str(self.offset), str(self.disk)]
            if inode:
                args.append(inode)
            result = subprocess.run(args, capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise RuntimeError(result.stderr)
            entries = {}
            for line in result.stdout.splitlines():
                match = re.match(r"(\S+)\s+([0-9]+(?:-[0-9]+)*):\s*(.*)", line)
                if match:
                    kind, number, name = match.groups()
                    entries[name.casefold()] = (name, number, kind)
            self.directory_cache[inode] = entries
        return self.directory_cache[inode]

    def lookup(self, path):
        inode = None
        found = None
        for part in Path(path).parts:
            found = self.directory(inode).get(part.casefold())
            if not found:
                return None
            inode = found[1]
        return found

    def extract(self, path, limit=128 * 1024**2):
        entry = self.lookup(path)
        if not entry or entry[2].startswith("d"):
            return
        target = self.out / path
        target.parent.mkdir(parents=True, exist_ok=True)
        total = 0
        checksum = hashlib.sha256()
        with subprocess.Popen(["icat", "-o", str(self.offset), str(self.disk), entry[1]], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as proc:
            with target.open("wb") as stream:
                while chunk := proc.stdout.read(1024**2):
                    total += len(chunk)
                    if total > limit:
                        proc.kill()
                        break
                    stream.write(chunk)
                    checksum.update(chunk)
            code = proc.wait(timeout=30)
        if total > limit or code:
            target.unlink()
            self.records.append({"path": path, "skipped": "size limit or extraction failure", "bytes_read": total})
        else:
            self.records.append({"path": path, "size": total, "sha256": checksum.hexdigest()})
            print("Extracted", path, total, flush=True)

    def collect(self):
        for path in ["Windows/MEMORY.DMP", "Windows/System32/winevt/Logs/System.evtx",
                     "Windows/System32/winevt/Logs/Setup.evtx", "Windows/Panther/setupact.log",
                     "Windows/Panther/setuperr.log", "Windows/System32/config/SYSTEM"]:
            self.extract(path, 768 * 1024**2 if path.endswith(".DMP") else 128 * 1024**2)
        entry = self.lookup("Windows/Minidump")
        if entry:
            for name, _, kind in self.directory(entry[1]).values():
                if not kind.startswith("d") and name.lower().endswith(".dmp"):
                    self.extract("Windows/Minidump/" + name)
        for root in ["ProgramData/Microsoft/Windows/WER/ReportArchive", "ProgramData/Microsoft/Windows/WER/ReportQueue"]:
            entry = self.lookup(root)
            if entry:
                for name, _, kind in self.directory(entry[1]).values():
                    if kind.startswith("d") and name.lower().startswith(("kernel_", "bluescreen_")):
                        self.extract(root + "/" + name + "/Report.wer")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("disk", type=Path)
    parser.add_argument("out", type=Path)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    summary = []
    for number, offset in partitions(args.disk):
        evidence = Evidence(args.disk, offset, args.out / ("partition-" + str(number)))
        try:
            if evidence.lookup("Windows"):
                evidence.collect()
                summary.append({"partition": number, "offset": offset, "files": evidence.records})
        except RuntimeError as error:
            summary.append({"partition": number, "offset": offset, "error": str(error)})
    (args.out / "extraction.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
