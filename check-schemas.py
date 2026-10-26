#!/usr/bin/env python3
"""Validate repository JSON documents against their schemas.

- Every adapter manifest against schemas/adapter.schema.json. This is the same
  validation the atrium app performs at install time (src-tauri
  schema_validator.rs, jsonschema draft 2020-12). validate-adapter.sh only runs
  structural jq checks, so without this gate a manifest can pass CI here yet be
  rejected by the app, which breaks Update All for every user (see the
  chatTransport incident, 2026-07-10).
- connectors/catalog.json against schemas/connectors-catalog.schema.json, plus
  the cross-field rules a JSON Schema cannot express (input references, auth
  evidence, pinned versions). See connectors/README.md.

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


def report(path, errors):
    rel = path.relative_to(root)
    if errors:
        print(f"FAIL {rel}")
        for location, message in errors:
            print(f"  at {location or '<root>'}: {message}")
        return 1
    print(f"ok   {rel}")
    return 0


def schema_errors(validator, document):
    errors = sorted(validator.iter_errors(document), key=lambda e: list(e.path))
    return [("/".join(str(p) for p in err.path), err.message) for err in errors]


def check_adapters():
    schema = json.loads((root / "schemas" / "adapter.schema.json").read_text())
    validator = Draft202012Validator(schema)
    manifests = sorted(root.glob("adapters/*/adapter.json"))
    if not manifests:
        print("check-schemas.py: no adapter manifests found", file=sys.stderr)
        sys.exit(2)
    failed = 0
    for manifest_path in manifests:
        manifest = json.loads(manifest_path.read_text())
        failed |= report(manifest_path, schema_errors(validator, manifest))
    return failed


def input_refs(value, where, out):
    """Collect (input name, location) for every {"input": name} under value."""
    if isinstance(value, dict):
        if set(value) == {"input"}:
            out.append((value["input"], where))
            return
        for key, child in value.items():
            input_refs(child, f"{where}/{key}", out)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            input_refs(child, f"{where}/{index}", out)


def preset_errors(index, preset):
    errors = []
    at = f"presets/{index}"
    server = preset["server"]
    verified = preset["verified"]

    declared = {}
    for position, field in enumerate(preset["inputs"]):
        if field["name"] in declared:
            errors.append((f"{at}/inputs/{position}", f"input '{field['name']}' is declared twice"))
        declared[field["name"]] = field
    refs = []
    input_refs(server, f"{at}/server", refs)
    for name, where in refs:
        if name not in declared:
            errors.append((where, f"references undeclared input '{name}'"))
    referenced = {name for name, _ in refs}
    for name in declared:
        if name not in referenced:
            errors.append((f"{at}/inputs", f"input '{name}' is never referenced by the server template"))

    if server["transport"] == "http":
        auth = server["auth"]
        credential = {"bearer": "token", "header": "value"}.get(auth["kind"])
        positions = [credential] if credential else []
        if auth["kind"] == "oauth" and "clientSecret" in auth:
            positions.append("clientSecret")
        for key in positions:
            ref = auth[key]
            if "input" not in ref or not declared.get(ref["input"], {}).get("secret"):
                errors.append((f"{at}/server/auth/{key}", "credentials must come from a secret input, never a literal"))
        if "mcp" not in verified:
            errors.append((f"{at}/verified", "remote presets need verified.mcp probe evidence"))
        if auth["kind"] == "oauth":
            evidence = verified.get("oauth")
            if evidence is None:
                errors.append((f"{at}/verified", "oauth presets need verified.oauth evidence"))
            else:
                observed = {
                    "cimd": evidence["clientIdMetadataDocumentSupported"],
                    "dcr": evidence["registrationEndpoint"] is not None,
                }
                if auth["advertised"] != observed:
                    errors.append((f"{at}/server/auth/advertised",
                                   f"{auth['advertised']} disagrees with verified.oauth evidence {observed}"))
                if "S256" not in evidence["codeChallengeMethodsSupported"]:
                    errors.append((f"{at}/verified/oauth", "authorization server does not advertise PKCE S256"))
    else:
        launch = server["launch"]
        if launch["kind"] == "package":
            evidence = verified.get("package")
            if evidence is None:
                errors.append((f"{at}/verified", "package presets need verified.package evidence"))
            elif (evidence["registry"], evidence["version"]) != (launch["ecosystem"], launch["version"]):
                errors.append((f"{at}/verified/package", "registry/version disagree with server.launch"))
        else:
            evidence = verified.get("image")
            tag = launch["image"].rsplit(":", 1)[1]
            if evidence is None:
                errors.append((f"{at}/verified", "docker presets need verified.image evidence"))
            elif (evidence["digest"], evidence["tag"]) != (launch["digest"], tag):
                errors.append((f"{at}/verified/image", "tag/digest disagree with server.launch"))

    if preset["toolPolicyDefaults"] and "toolNamesSource" not in verified:
        errors.append((f"{at}/verified", "toolPolicyDefaults need verified.toolNamesSource"))
    return errors


def check_connectors_catalog():
    catalog_path = root / "connectors" / "catalog.json"
    schema = json.loads((root / "schemas" / "connectors-catalog.schema.json").read_text())
    Draft202012Validator.check_schema(schema)
    catalog = json.loads(catalog_path.read_text())
    errors = schema_errors(Draft202012Validator(schema), catalog)
    if errors:
        return report(catalog_path, errors)
    seen = set()
    for index, preset in enumerate(catalog["presets"]):
        if preset["id"] in seen:
            errors.append((f"presets/{index}/id", f"duplicate preset id '{preset['id']}'"))
        seen.add(preset["id"])
        if preset["verified"]["date"] > catalog["updatedAt"]:
            errors.append((f"presets/{index}/verified/date", "is later than the catalog's updatedAt"))
        errors.extend(preset_errors(index, preset))
    return report(catalog_path, errors)


failed = check_adapters()
failed |= check_connectors_catalog()
sys.exit(failed)
