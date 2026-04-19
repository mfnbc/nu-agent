#!/usr/bin/env python3
"""
Simple JSONL -> NUON converter used as a pragmatic fallback.

This script reads a newline-delimited JSON file (chunks.jsonl) and writes two
NUON-shaped files under data/:
 - data/nu_docs_vectors.nuon  (list of chunk records)
 - data/command_map.nuon      (map from lowercase command -> { id, display })

Implementation note: NUON is a superset of JSON for the shapes we write here,
so emitting pretty JSON is acceptable for Nushell's `open` in most versions.
If you require more exact NUON serialization, replace this with a Rust helper.
"""
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
in_path = root / "build" / "nu_ingest" / "chunks.jsonl"
out_vectors = root / "data" / "nu_docs_vectors.nuon"
out_command_map = root / "data" / "command_map.nuon"

if not in_path.exists():
    print(f"Input not found: {in_path}")
    sys.exit(1)

out_vectors.parent.mkdir(parents=True, exist_ok=True)

rows = []
cmd_map = {}

with in_path.open("r", encoding="utf-8") as fh:
    for ln in fh:
        ln = ln.strip()
        if not ln:
            continue
        try:
            obj = json.loads(ln)
        except Exception:
            continue
        rows.append(obj)
        tax = obj.get("taxonomy") or {}
        cmds = tax.get("commands") or []
        for c in cmds:
            key = c.lower()
            if key not in cmd_map:
                cmd_map[key] = {"id": obj.get("id"), "display": c}

# Write pretty JSON to .nuon files (NUON accepts JSON shapes for these uses)
with out_vectors.open("w", encoding="utf-8") as fh:
    json.dump(rows, fh, indent=2, ensure_ascii=False)

with out_command_map.open("w", encoding="utf-8") as fh:
    json.dump(cmd_map, fh, indent=2, ensure_ascii=False)

print(f"Wrote: {len(rows)} vectors -> {out_vectors}")
print(f"Wrote: {len(cmd_map)} command map entries -> {out_command_map}")
