"""Elasticsearch helpers for APM analysis scripts.

Loads credentials from ~/config/apm.creds (KEY=value), with process env overrides.
"""

from __future__ import annotations

import base64
import json
import os
import urllib.error
import urllib.request
from pathlib import Path

CREDS_PATH = Path.home() / "config" / "apm.creds"


def load_creds(path: Path = CREDS_PATH) -> dict[str, str]:
    out: dict[str, str] = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    for key in ("APM_ES_URL", "APM_ES_USER", "APM_ES_PASSWORD", "APM_INDEX"):
        if os.environ.get(key):
            out[key] = os.environ[key]
    for req in ("APM_ES_URL", "APM_ES_USER", "APM_ES_PASSWORD"):
        if not out.get(req):
            raise RuntimeError(
                f"{req} missing — create/edit {path} "
                "(see apm-investigation skill session bootstrap)"
            )
    if "YOUR-MONITORING-ES" in out["APM_ES_URL"] or out["APM_ES_PASSWORD"] == "change-me":
        raise RuntimeError(
            f"Sample placeholders still in {path} — ask the user to edit real values"
        )
    out.setdefault("APM_INDEX", "traces-apm*")
    return out


def auth_header(creds: dict[str, str]) -> str:
    token = base64.b64encode(
        f"{creds['APM_ES_USER']}:{creds['APM_ES_PASSWORD']}".encode()
    ).decode()
    return f"Basic {token}"


def es_request(
    creds: dict[str, str],
    path: str,
    body: dict | None = None,
    method: str | None = None,
    timeout: float = 120,
) -> dict:
    url = creds["APM_ES_URL"].rstrip("/") + path
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": auth_header(creds),
            "Content-Type": "application/json",
        },
        method=method or ("POST" if data is not None else "GET"),
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")[:2000]
        raise RuntimeError(f"HTTP {e.code} {path}: {err_body}") from e


def esql(creds: dict[str, str], query: str) -> dict:
    return es_request(creds, "/_query?format=json", {"query": query})


def esql_rows(result: dict) -> list[dict]:
    cols = [c["name"] for c in result.get("columns", [])]
    return [dict(zip(cols, row)) for row in result.get("values", [])]
