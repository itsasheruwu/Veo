"""Fail if the committed baseline inventory or ledger is structurally incomplete."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent
manifest = json.loads((root / "source-manifest.json").read_text(encoding="utf-8"))
ledger = json.loads((root / "parity-records.json").read_text(encoding="utf-8"))
records = ledger.get("records", []) if isinstance(ledger, dict) else ledger
ids = {record["id"] for record in records}
expected = {f"{prefix}{n:02d}" for prefix, count in {"W":9,"C":18,"M":8,"G":14,"T":7,"B":11,"R":14,"S":12}.items() for n in range(1, count+1)}
assert ids == expected, f"Parity ledger mismatch: missing={expected-ids}, extra={ids-expected}"
assert len(records) == 93, "Duplicate ledger IDs"
assert manifest, "Empty baseline source manifest"
print(f"PASS: {len(records)} unique parity records and baseline source manifest")
