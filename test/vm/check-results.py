"""Reject partial acceptance, missing receipts, and receipts for another image."""
import json
from pathlib import Path
import re
import sys

EXPECTED = {"accept": "completed", "undo": "rolled_back", "powercut-undo": "rolled_back", "powercut-accept": "completed", "powercut-apply": "rolled_back"}
HEX = re.compile(r"[0-9a-f]{64}")

def validate(report, image_digest=None):
    if report.get("status") != "passed" or report.get("native") is not True:
        raise ValueError("VM acceptance did not pass with native tests enabled")
    results = report.get("results", [])
    actual = [item.get("case") for item in results]
    if len(actual) != len(EXPECTED) or set(actual) != set(EXPECTED):
        raise ValueError(f"Incomplete VM matrix: {actual}")
    for item in results:
        receipt = item.get("receipt", {})
        if receipt.get("version") != 4:
            raise ValueError("Unsupported completion receipt version")
        if item.get("outcome") != EXPECTED[item["case"]] or receipt.get("outcome") != item["outcome"]:
            raise ValueError("Unexpected completion or rollback outcome")
        if item.get("idempotent") is not True or receipt.get("id") != item.get("id"):
            raise ValueError("Missing idempotent receipt import")
        for key in ("id", "plan_digest", "program_digest", "disk_identity", "image_digest"):
            if not HEX.fullmatch(receipt.get(key, "")):
                raise ValueError(f"Missing receipt binding: {key}")
        if image_digest is not None and receipt["image_digest"] != image_digest:
            raise ValueError("Receipt belongs to another maintenance image")
    return len(actual)

if __name__ == "__main__":
    try:
        count = validate(json.loads(Path(sys.argv[1]).read_text()))
    except (ValueError, KeyError) as error:
        raise SystemExit(str(error))
    print(f"Complete VM acceptance: {count}/{len(EXPECTED)}, native tests and receipt import enabled")
