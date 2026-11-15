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
- connectors/official-listings.json against
  schemas/connectors-listings.schema.json, plus unique ids and names, a
  namespace that is its endpoint's host reversed, and no preset's server.
- connectors/vendors.json against schemas/connectors-vendors.schema.json, plus
  one owner per word and per root, no generic owned word, no shared-host
  root, and every listing's claimed vendor word served from that vendor.
- connectors/companions.json against schemas/connectors-companions.schema.json,
  plus unique ids, a preset behind each, the companion.<id> token handle, no
  flag listed as two kinds, and no repeated rule.
- hq/library.json against schemas/hq-library.schema.json, then
  scripts/build-hq-library.mjs --check: the compiled library matches its
  hq/library/**/*.md sources and passes the rules a schema can't express
  (slots, refs, presets, effects, schedules, sizes). See hq/README.md.

Requires: pip install jsonschema
"""

import json
from urllib.parse import urlsplit
import subprocess
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


# Hosts anyone can put a name under (atrium's classify.rs SHARED_HOSTS): a
# page or endpoint there proves nothing about who the vendor is.
SHARED_HOSTS = (
    "vercel.app", "vercel.dev", "netlify.app", "github.io", "gitlab.io", "pages.dev", "workers.dev",
    "herokuapp.com", "onrender.com", "fly.dev", "railway.app", "web.app", "firebaseapp.com",
    "azurewebsites.net", "azurestaticapps.net", "appspot.com", "glitch.me", "replit.app", "replit.dev",
    "repl.co", "deno.dev", "ngrok.io", "ngrok.app", "ngrok-free.app", "surge.sh", "amplifyapp.com",
    "streamlit.app", "hf.space", "modal.run", "koyeb.app", "lovable.app", "framer.app",
    "framer.website", "webflow.io", "wixsite.com", "codeberg.page", "pythonanywhere.com",
    "cloudfront.net", "supabase.co", "smithery.ai", "run.app", "trycloudflare.com", "lhr.life",
    "sslip.io", "duckdns.org", "alpic.live", "chatgpt.site", "fastmcp.app",
)


def on_shared_host(url):
    import re
    host = url.split("://", 1)[-1].split("/", 1)[0].split(":", 1)[0].lower()
    return any(host == shared or host.endswith("." + shared) for shared in SHARED_HOSTS) or bool(
        re.search(r"\.execute-api\.[^.]+\.amazonaws\.com$|\.lambda-url\.[^.]+\.on\.aws$", host)
    )


def listing_host_name(url):
    """`com.googleapis.drivemcp` for https://drivemcp.googleapis.com/…"""
    host = url.split("://", 1)[1].split("/", 1)[0].split(":", 1)[0].lower()
    return ".".join(reversed(host.split(".")))


STOP_WORDS = {
    "mcp", "server", "servers", "the", "and", "for", "with", "your", "you", "from", "that", "this",
    "into", "via", "using", "an", "of", "to", "in", "on", "by", "or", "is", "it", "its", "are",
    "be", "can", "all", "any", "model", "protocol", "provides", "lets", "allows",
}


def listing_words(text):
    """A text's words as atrium's index reads them (index.rs `words`)."""
    import re
    return [
        word for word in (w.lower() for w in re.split(r"[^\w]|_", text) if len(w) >= 2)
        if word not in STOP_WORDS
    ]


def check_connectors_listings():
    listings_path = root / "connectors" / "official-listings.json"
    schema = json.loads((root / "schemas" / "connectors-listings.schema.json").read_text())
    Draft202012Validator.check_schema(schema)
    document = json.loads(listings_path.read_text())
    errors = schema_errors(Draft202012Validator(schema), document)
    if errors:
        return report(listings_path, errors)
    catalog = json.loads((root / "connectors" / "catalog.json").read_text())
    preset_urls = {p["server"].get("url") for p in catalog["presets"]}
    ids, names = set(), set()
    for index, listing in enumerate(document["listings"]):
        at = f"listings/{index}"
        server = listing["server"]
        if listing["id"] in ids:
            errors.append((f"{at}/id", f"duplicate listing id '{listing['id']}'"))
        ids.add(listing["id"])
        if server["name"] in names:
            errors.append((f"{at}/server/name", f"duplicate server name '{server['name']}'"))
        names.add(server["name"])
        if listing["verified"]["date"] > document["updatedAt"]:
            errors.append((f"{at}/verified/date", "is later than the listings' updatedAt"))
        namespace = server["name"].split("/", 1)[0]
        url = server["remotes"][0]["url"]
        host_name = listing_host_name(url)
        if host_name != namespace and not host_name.startswith(namespace + "."):
            errors.append((f"{at}/server/name", f"namespace should be '{host_name}', the reverse of its endpoint's host"))
        # An endpoint on the vendor's own domain proves who serves it; one on a
        # shared host proves nothing, so the vendor's own pages must name it.
        if any(on_shared_host(remote["url"]) for remote in server["remotes"]) and all(
            on_shared_host(source) for source in listing["verified"]["sources"] + [listing["docsUrl"]]
        ):
            errors.append((f"{at}/verified/sources", "served from a shared host, and no source on the vendor's own domain names it"))
        title_words = listing_words(server["title"])
        named = set(title_words) | set(listing_words(server["name"].split("/", 1)[1]))
        for size in (2, 3):
            named |= {"".join(title_words[at:at + size]) for at in range(len(title_words) - size + 1)}
        for word in listing.get("owns", []):
            if word not in named:
                errors.append((f"{at}/owns", f"'{word}' isn't a word of its title or name"))
        for remote in server["remotes"]:
            if remote["url"] in preset_urls:
                errors.append((f"{at}/server/remotes", f"{remote['url']} is a catalog preset already: the preset is its listing"))
    return report(listings_path, errors)


def check_connectors_vendors():
    vendors_path = root / "connectors" / "vendors.json"
    schema = json.loads((root / "schemas" / "connectors-vendors.schema.json").read_text())
    Draft202012Validator.check_schema(schema)
    document = json.loads(vendors_path.read_text())
    errors = schema_errors(Draft202012Validator(schema), document)
    if errors:
        return report(vendors_path, errors)
    generic = set(document["genericWords"])
    ids, word_owner, root_owner = set(), {}, {}
    for index, vendor in enumerate(document["vendors"]):
        at = f"vendors/{index}"
        if vendor["id"] in ids:
            errors.append((f"{at}/id", f"duplicate vendor id '{vendor['id']}'"))
        ids.add(vendor["id"])
        for word in vendor["owns"]:
            if word in generic:
                errors.append((f"{at}/owns", f"'{word}' is a generic word"))
            if word in word_owner:
                errors.append((f"{at}/owns", f"'{word}' is {word_owner[word]}'s too: a word has one owner"))
            word_owner[word] = vendor["id"]
        if "searchedAs" in vendor and vendor["searchedAs"] not in vendor["owns"]:
            errors.append((f"{at}/searchedAs", "must be one of its owned words"))
        own_domains = [
            ".".join(reversed(r["root"].split("."))) for r in vendor["roots"] if not r["root"].startswith("io.github.")
        ]
        for item in vendor["roots"]:
            domain = ".".join(reversed(item["root"].split(".")))
            source_host = (urlsplit(item["source"]).hostname or "").lower()
            if source_host == "registry.modelcontextprotocol.io":
                errors.append((f"{at}/roots", f"{item['root']}: a registry search proves no one's ownership"))
            if item["root"].startswith("io.github."):
                org = item["root"][len("io.github."):]
                on_own_domain = any(source_host == d or source_host.endswith("." + d) for d in own_domains)
                if item["source"].rstrip("/").lower() != f"https://api.github.com/orgs/{org}" and not on_own_domain:
                    errors.append((f"{at}/roots", f"{item['root']}: cite https://api.github.com/orgs/{org} (a verified organization) or a page on the vendor's own domain"))
            if not item["root"].startswith("io.github.") and on_shared_host("https://" + domain):
                errors.append((f"{at}/roots", f"{item['root']} is a shared host: it proves no one"))
            if item["root"] in root_owner:
                errors.append((f"{at}/roots", f"{item['root']} is {root_owner[item['root']]}'s too: a root has one owner"))
            root_owner[item["root"]] = vendor["id"]
    # An exact endpoint on someone else's host needs a page on the vendor's
    # own domain naming it, and one owner.
    endpoint_owner = {}
    for index, vendor in enumerate(document["vendors"]):
        own_domains = [
            ".".join(reversed(r["root"].split("."))) for r in vendor["roots"] if not r["root"].startswith("io.github.")
        ]
        for item in vendor.get("endpoints", []):
            at = f"vendors/{index}/endpoints"
            source_host = (urlsplit(item["source"]).hostname or "").lower()
            if source_host == "registry.modelcontextprotocol.io" or not any(
                source_host == d or source_host.endswith("." + d) for d in own_domains
            ):
                errors.append((at, f"{item['url']}: cite a page on {vendor['id']}'s own domain that names it"))
            parts = urlsplit(item["url"])
            if parts.username or parts.password or parts.query or parts.fragment:
                errors.append((at, f"{item['url']}: an exact endpoint, with no credentials, query or fragment"))
            key = item["url"].rstrip("/").lower()
            if key in endpoint_owner:
                errors.append((at, f"{item['url']} is {endpoint_owner[key]}'s too"))
            endpoint_owner[key] = vendor["id"]
    # A listing claiming a vendor's word must be served from that vendor's roots.
    listings = json.loads((root / "connectors" / "official-listings.json").read_text())["listings"]
    vendor_roots = {v["id"]: [r["root"] for r in v["roots"]] for v in document["vendors"]}
    for index, listing in enumerate(listings):
        for word in listing.get("owns", []):
            if word in generic:
                errors.append((f"official-listings/{index}/owns", f"'{word}' is a generic word"))
            owner = word_owner.get(word)
            if not owner:
                continue
            hosts = [(urlsplit(r["url"]).hostname or "").lower() for r in listing["server"]["remotes"]]
            domains = [".".join(reversed(r.split("."))) for r in vendor_roots[owner] if not r.startswith("io.github.")]
            # Every endpoint, parsed as a URL, on one of the owner's domains.
            if not hosts or not all(any(h == d or h.endswith("." + d) for d in domains) for h in hosts):
                errors.append((f"official-listings/{index}/owns", f"'{word}' is {owner}'s, but the listing isn't served from its roots"))
    return report(vendors_path, errors)


def check_hq_library():
    library_path = root / "hq" / "library.json"
    schema = json.loads((root / "schemas" / "hq-library.schema.json").read_text())
    Draft202012Validator.check_schema(schema)
    library = json.loads(library_path.read_text())
    failed = report(library_path, schema_errors(Draft202012Validator(schema), library))
    built = subprocess.run(
        ["node", str(root / "scripts" / "build-hq-library.mjs"), "--check"],
        capture_output=True,
        text=True,
    )
    sys.stdout.write(built.stdout)
    sys.stdout.write(built.stderr)
    return failed | (1 if built.returncode else 0)


def companion_errors(index, companion, presets):
    at = f"companions/{index}"
    errors = []
    cid = companion["id"]
    preset = presets.get(companion["presetId"])
    if preset is None:
        errors.append((f"{at}/presetId", f"'{companion['presetId']}' isn't a catalog preset"))
    elif preset["verified"]["status"] != "verified" and preset["verified"].get("flagReason") != "client-approval-required":
        errors.append((f"{at}/presetId", "a companion belongs to a Verified preset"))
    if companion["token"]["secret"] != f"companion.{cid}":
        errors.append((f"{at}/token/secret", f"must be companion.{cid}: only the companion route injects those"))
    commands = companion["commands"]
    if set(commands["valueFlags"]) & set(commands["credentialFlags"]):
        errors.append((f"{at}/commands", "a flag is listed both as taking a value and as a credential"))
    seen = set()
    for r_index, rule in enumerate(commands["rules"]):
        key = (tuple(rule["path"]), json.dumps(rule.get("flag"), sort_keys=True))
        if key in seen:
            errors.append((f"{at}/commands/rules/{r_index}", "repeats an earlier rule, which always wins"))
        seen.add(key)
    return errors


def check_connectors_companions():
    path = root / "connectors" / "companions.json"
    schema = json.loads((root / "schemas" / "connectors-companions.schema.json").read_text())
    Draft202012Validator.check_schema(schema)
    document = json.loads(path.read_text())
    errors = schema_errors(Draft202012Validator(schema), document)
    if errors:
        return report(path, errors)
    catalog = json.loads((root / "connectors" / "catalog.json").read_text())
    presets = {p["id"]: p for p in catalog["presets"]}
    ids = set()
    for index, companion in enumerate(document["companions"]):
        if companion["id"] in ids:
            errors.append((f"companions/{index}/id", "is listed twice"))
        ids.add(companion["id"])
        errors.extend(companion_errors(index, companion, presets))
        if companion["verified"]["date"] > document["updatedAt"]:
            errors.append((f"companions/{index}/verified/date", "is later than the file's updatedAt"))
    return report(path, errors)


failed = check_adapters()
failed |= check_connectors_catalog()
failed |= check_connectors_listings()
failed |= check_connectors_vendors()
failed |= check_connectors_companions()
failed |= check_hq_library()
sys.exit(failed)
