#!/usr/bin/env python3
"""Probe a remote MCP server the way connectors/README.md asks, without credentials.

    python3 scripts/probe-connector.py https://mcp.example.com/mcp [--tools]

Prints the `verified.mcp` and (on a 401) `verified.oauth` evidence for
connectors/catalog.json. It sends a 2026-07-28 server/discover, then a
2025-era initialize, then follows WWW-Authenticate resource_metadata (RFC 9728)
to the authorization server metadata (RFC 8414, then OpenID discovery).
--tools also lists tools when the server answers without sign-in.

Read-only and unauthenticated: no tokens, no client registration, short curl
timeouts. A 2025-era session it opens is closed with DELETE.
"""

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

MODERN = "2026-07-28"
LEGACY = "2025-11-25"
CLIENT = {"name": "atrium-catalog-probe", "version": "1.0.0"}
META = {
    "io.modelcontextprotocol/protocolVersion": MODERN,
    "io.modelcontextprotocol/clientInfo": CLIENT,
    "io.modelcontextprotocol/clientCapabilities": {},
}
ACCEPT = "application/json, text/event-stream"


def curl(method, url, headers=None, body=None):
    with tempfile.TemporaryDirectory() as tmp:
        head_path = Path(tmp) / "headers"
        body_path = Path(tmp) / "body"
        cmd = ["curl", "-sS", "-m", "12", "--connect-timeout", "6", "-X", method,
               "-D", str(head_path), "-o", str(body_path), "-w", "%{http_code}",
               "-A", "atrium-catalog-probe/1.0"]
        for key, value in (headers or {}).items():
            cmd += ["-H", f"{key}: {value}"]
        if body is not None:
            cmd += ["--data-binary", json.dumps(body)]
        cmd.append(url)
        proc = subprocess.run(cmd, capture_output=True, text=True)
        raw_headers = head_path.read_text(errors="replace") if head_path.exists() else ""
        text = body_path.read_bytes()[:200000].decode("utf-8", "replace") if body_path.exists() else ""
    blocks = [b for b in re.split(r"\r?\n\r?\n", raw_headers.strip()) if b.strip()]
    parsed = {}
    for line in (blocks[-1] if blocks else "").splitlines()[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            parsed.setdefault(key.strip().lower(), []).append(value.strip())
    status = proc.stdout.strip()
    return {"status": int(status) if status.isdigit() else 0, "headers": parsed,
            "body": text, "error": proc.stderr.strip()}


def payload(text):
    try:
        return json.loads(text)
    except ValueError:
        pass
    for line in text.splitlines():
        if line.startswith("data:"):
            try:
                message = json.loads(line[5:])
            except ValueError:
                continue
            if isinstance(message, dict) and ("result" in message or "error" in message):
                return message
    return None


def outcome(resp):
    out = {"status": resp["status"]}
    message = payload(resp["body"])
    if isinstance(message, dict) and isinstance(message.get("result"), dict):
        result = message["result"]
        if isinstance(result.get("protocolVersion"), str):
            out["protocolVersion"] = result["protocolVersion"]
        if isinstance(result.get("supportedVersions"), list):
            out["supportedVersions"] = result["supportedVersions"]
    elif isinstance(message, dict) and "error" in message:
        error = message["error"]
        if isinstance(error, dict):
            code = error.get("code")
            text = str(error.get("message", ""))
            out["error"] = (f"{code}: {text}" if code is not None else text)[:160]
        else:
            out["error"] = str(error)[:160]
    elif resp["error"]:
        out["error"] = resp["error"][:160]
    return out


def discover(url):
    return curl("POST", url, {"Content-Type": "application/json", "Accept": ACCEPT,
                              "MCP-Protocol-Version": MODERN, "Mcp-Method": "server/discover"},
                {"jsonrpc": "2.0", "id": 1, "method": "server/discover",
                 "params": {"_meta": META}})


def initialize(url):
    return curl("POST", url, {"Content-Type": "application/json", "Accept": ACCEPT},
                {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                 "params": {"protocolVersion": LEGACY, "capabilities": {}, "clientInfo": CLIENT}})


def well_known(base, suffix):
    parts = urlsplit(base)
    path = parts.path.rstrip("/")
    urls = [urlunsplit((parts.scheme, parts.netloc, f"/.well-known/{suffix}{path}", "", ""))]
    if path:
        urls.append(urlunsplit((parts.scheme, parts.netloc, f"/.well-known/{suffix}", "", "")))
    return urls


def get_json(url):
    resp = curl("GET", url, {"Accept": "application/json"})
    if resp["status"] != 200:
        return None
    try:
        doc = json.loads(resp["body"])
    except ValueError:
        return None
    return doc if isinstance(doc, dict) else None


def oauth_evidence(url, www_authenticate):
    match = re.search(r'resource_metadata="([^"]+)"', www_authenticate or "")
    advertised = match.group(1) if match else None
    prm_url, prm = None, None
    for candidate in ([advertised] if advertised else []) + well_known(url, "oauth-protected-resource"):
        doc = get_json(candidate)
        if doc and doc.get("authorization_servers"):
            prm_url, prm = candidate, doc
            break
    if prm:
        servers = prm["authorization_servers"]
    else:
        # 2025-03-26 servers publish authorization server metadata at their origin.
        parts = urlsplit(url)
        servers = [urlunsplit((parts.scheme, parts.netloc, "", "", ""))]
    for suffix in ("oauth-authorization-server", "openid-configuration"):
        for candidate in well_known(servers[0], suffix):
            doc = get_json(candidate)
            if doc and doc.get("authorization_endpoint"):
                return {
                    "wwwAuthenticateResourceMetadata": advertised is not None,
                    "resourceMetadataUrl": prm_url,
                    "authorizationServers": servers if prm else [],
                    "authorizationServerMetadataUrl": candidate,
                    "clientIdMetadataDocumentSupported": doc.get(
                        "client_id_metadata_document_supported") is True,
                    "registrationEndpoint": doc.get("registration_endpoint"),
                    "codeChallengeMethodsSupported": doc.get("code_challenge_methods_supported") or [],
                }
    return {"error": "no authorization server metadata found", "authorizationServers": servers}


def list_tools(url, eras, session_id, negotiated):
    if "2026-07-28" in eras:
        resp = curl("POST", url, {"Content-Type": "application/json", "Accept": ACCEPT,
                                  "MCP-Protocol-Version": MODERN, "Mcp-Method": "tools/list"},
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {"_meta": META}})
    else:
        headers = {"Content-Type": "application/json", "Accept": ACCEPT,
                   "MCP-Protocol-Version": negotiated}
        if session_id:
            headers["Mcp-Session-Id"] = session_id
        curl("POST", url, headers, {"jsonrpc": "2.0", "method": "notifications/initialized"})
        resp = curl("POST", url, headers,
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    message = payload(resp["body"]) or {}
    tools = (message.get("result") or {}).get("tools") or []
    return [{"name": t.get("name"), "annotations": t.get("annotations") or {}} for t in tools]


def probe(url, with_tools):
    modern = discover(url)
    legacy = initialize(url)
    mcp = {"discover": outcome(modern), "initialize": outcome(legacy), "eras": []}
    if modern["status"] == 200 and "supportedVersions" in mcp["discover"]:
        mcp["eras"].append("2026-07-28")
    if legacy["status"] == 200 and "protocolVersion" in mcp["initialize"]:
        mcp["eras"].append("2025")
    report = {"url": url, "mcp": mcp}
    session_id = (legacy["headers"].get("mcp-session-id") or [None])[0]
    if with_tools and mcp["eras"]:
        negotiated = mcp["initialize"].get("protocolVersion", LEGACY)
        report["tools"] = list_tools(url, mcp["eras"], session_id, negotiated)
    if session_id:
        curl("DELETE", url, {"Mcp-Session-Id": session_id, "MCP-Protocol-Version": LEGACY})
    if 401 in (modern["status"], legacy["status"]):
        www = None
        for resp in (modern, legacy):
            if resp["status"] == 401 and resp["headers"].get("www-authenticate"):
                www = " ".join(resp["headers"]["www-authenticate"])
                break
        report["oauth"] = oauth_evidence(url, www)
    return report


def main(argv):
    urls = [a for a in argv if not a.startswith("--")]
    if not urls:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    reports = [probe(url, "--tools" in argv) for url in urls]
    print(json.dumps(reports if len(reports) > 1 else reports[0], indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
