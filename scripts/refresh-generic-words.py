#!/usr/bin/env python3
"""Recompute connectors/vendors.json's genericWords.

They are words no registry domain's name makes a brand: the reviewed core
below, plus every everyday word (in the system dictionary, /usr/share/dict/words;
a plural by its singular) that a domain in the registry digest is named for
("trading" for a trading.ltd.uk), less every word atrium curates (a vendor's, a
listing's, a preset's), which a review vouched for. Run it after rebuilding the
digest, then `node scripts/build-registry-digest.mjs --listings-only`.

Usage: python3 scripts/refresh-generic-words.py
"""

import gzip
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
connectors = root / "connectors"

# Reviewed: generic words and domain-hack labels that hold servers back
# (ATR-1150's generic-proven-brands.json measured ai, api, app, dev, net, pro,
# co, apis, tech and bots; the rest are their siblings).
CORE = [
    "ai", "api", "apis", "app", "apps", "dev", "net", "pro", "co", "io", "tech", "bot", "bots",
    "cloud", "web", "online", "site", "sites", "mcp", "hub", "labs", "data", "docs", "tools",
    "digital", "systems", "solutions", "software", "studio", "global", "group", "network",
    "services", "platform", "inc", "llc", "ltd", "corp", "team", "world", "live", "link", "my",
    "get", "go", "use", "try",
]

dictionary = {line.strip().lower() for line in open("/usr/share/dict/words")}


def everyday(word):
    return word in dictionary or (word.endswith("s") and word[:-1] in dictionary) or (
        word.endswith("es") and word[:-2] in dictionary
    )


vendors_path = connectors / "vendors.json"
document = json.loads(vendors_path.read_text())
curated = {word for vendor in document["vendors"] for word in vendor["owns"]}
listings = json.loads((connectors / "official-listings.json").read_text())["listings"]
curated |= {word for listing in listings for word in listing.get("owns", [])}
presets = json.loads((connectors / "catalog.json").read_text())["presets"]
curated |= {preset["id"] for preset in presets if "-" not in preset["id"]}

labels = set()
with gzip.open(connectors / "registry-digest.ndjson.gz", "rt") as digest:
    for line in digest:
        if not line.startswith('{"server":'):
            continue
        namespace = json.loads(line)["server"]["name"].split("/", 1)[0].lower()
        if not namespace.startswith("io.github."):
            labels.update(namespace.split(".")[1:])

found = {w for w in labels if len(w) >= 2 and w.isalnum() and everyday(w) and w not in curated}
document["genericWords"] = sorted((set(CORE) - curated) | found)
vendors_path.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")
print(f"{len(document['genericWords'])} generic words ({len(found)} everyday domain labels)")
