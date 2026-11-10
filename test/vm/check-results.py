"""Reject partial, skipped or otherwise incomplete VM acceptance reports."""
import json
from pathlib import Path
import sys

report = json.loads(Path(sys.argv[1]).read_text())
expected = {"accept", "undo", "powercut-undo", "powercut-accept", "powercut-apply"}
if report.get("status") != "passed" or report.get("native") is not True:
    raise SystemExit("VM acceptance did not pass with native tests enabled")
results = report.get("results", [])
actual = [item["case"] for item in results]
if len(actual) != len(expected) or set(actual) != expected:
    raise SystemExit(f"Incomplete VM matrix: {actual}")
print(f"Complete VM acceptance: {len(actual)}/{len(expected)}, native tests enabled")
