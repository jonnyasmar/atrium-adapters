#!/usr/bin/env python3
"""Validate every adapter manifest against schemas/adapter.schema.json.

This is the same validation the atrium app performs at install time
(src-tauri schema_validator.rs, jsonschema draft 2020-12). validate-adapter.sh
only runs structural jq checks, so without this gate a manifest can pass CI
here yet be rejected by the app — which breaks Update All for every user
(see the chatTransport incident, 2026-07-10).

Requires: pip install jsonschema
"""

import json
import sys
from pathlib import Path

try:
    from jsonschema import Draft202012Validator
except ImportError:
    print("check-schemas.py: pip install jsonschema", file=sys.stderr)
    sys.exit(2)

root = Path(__file__).resolve().parent
schema = json.loads((root / "schemas" / "adapter.schema.json").read_text())
validator = Draft202012Validator(schema)

failed = 0
manifests = sorted(root.glob("adapters/*/adapter.json"))
if not manifests:
    print("check-schemas.py: no adapter manifests found", file=sys.stderr)
    sys.exit(2)

for manifest_path in manifests:
    manifest = json.loads(manifest_path.read_text())
    errors = sorted(validator.iter_errors(manifest), key=lambda e: list(e.path))
    if errors:
        failed = 1
        print(f"FAIL {manifest_path.relative_to(root)}")
        for err in errors:
            loc = "/".join(str(p) for p in err.path) or "<root>"
            print(f"  at {loc}: {err.message}")
    else:
        print(f"ok   {manifest_path.relative_to(root)}")

sys.exit(failed)
