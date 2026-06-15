#!/usr/bin/env python3
"""
pihole6_exporter.py — minimal Prometheus exporter for Pi-hole v6's
session-based API.

Why this exists: Pi-hole v5 exporters authenticate with a static API
token in a query string (`?auth=<token>`). Pi-hole v6 replaced this with
session-based auth — POST credentials to /api/auth, get a session ID
(SID), and include it on subsequent requests. Exporters written for v5
fail silently or with auth errors after an in-place v5 -> v6 upgrade.

This exporter:
  - Authenticates once via POST /api/auth
  - Reuses the session for subsequent scrapes (re-authenticates on 401,
    and avoids exceeding webserver.api.max_sessions by NOT logging in on
    every scrape)
  - Reads /api/stats/summary and /api/stats/query_types
  - Handles the v6 query_types response shape: {"types": {"A": n, ...}}
    (v5 returned a flat list under a different key — code that assumes
    the old shape will KeyError or silently report zero)

Environment variables:
  PIHOLE_HOST       - Pi-hole host (default: localhost)
  PIHOLE_PASSWORD   - Pi-hole web interface password (required)
  EXPORTER_PORT     - port to serve /metrics on (default: 9617)

Run:
  PIHOLE_PASSWORD=... python3 pihole6_exporter.py
"""
import os
import time

import requests
from prometheus_client import start_http_server, Gauge

PIHOLE_HOST = os.environ.get("PIHOLE_HOST", "localhost")
PIHOLE_PASSWORD = os.environ["PIHOLE_PASSWORD"]
EXPORTER_PORT = int(os.environ.get("EXPORTER_PORT", "9617"))
SCRAPE_INTERVAL = int(os.environ.get("SCRAPE_INTERVAL", "15"))

BASE_URL = f"http://{PIHOLE_HOST}/api"

# Metrics
queries_total = Gauge("pihole_dns_queries_total", "Total DNS queries")
queries_blocked = Gauge("pihole_dns_queries_blocked_total", "Blocked DNS queries")
block_percent = Gauge("pihole_block_percentage", "Percentage of queries blocked")
domains_blocked = Gauge("pihole_domains_being_blocked", "Domains on blocklists")
clients_active = Gauge("pihole_active_clients", "Active clients")
query_by_type = Gauge("pihole_query_by_type", "Queries by DNS record type", ["type"])

_session_id = None


def authenticate():
    global _session_id
    resp = requests.post(f"{BASE_URL}/auth", json={"password": PIHOLE_PASSWORD}, timeout=10)
    resp.raise_for_status()
    _session_id = resp.json()["session"]["sid"]


def api_get(path: str) -> dict:
    global _session_id
    if _session_id is None:
        authenticate()

    resp = requests.get(f"{BASE_URL}{path}", headers={"X-FTL-SID": _session_id}, timeout=10)
    if resp.status_code == 401:
        # Session expired — re-authenticate once and retry
        authenticate()
        resp = requests.get(f"{BASE_URL}{path}", headers={"X-FTL-SID": _session_id}, timeout=10)

    resp.raise_for_status()
    return resp.json()


def collect():
    summary = api_get("/stats/summary")
    queries = summary.get("queries", {})
    queries_total.set(queries.get("total", 0))
    queries_blocked.set(queries.get("blocked", 0))
    block_percent.set(queries.get("percent_blocked", 0))
    domains_blocked.set(summary.get("gravity", {}).get("domains_being_blocked", 0))
    clients_active.set(summary.get("clients", {}).get("active", 0))

    # v6 shape: {"types": {"A": 123, "AAAA": 45, ...}}
    # (NOT a list — a common bug when porting v5 code is assuming a list
    # of {"name": ..., "count": ...} dicts here)
    types = api_get("/stats/query_types").get("types", {})
    for qtype, count in types.items():
        query_by_type.labels(type=qtype).set(count)


def main():
    start_http_server(EXPORTER_PORT)
    print(f"pihole6_exporter listening on :{EXPORTER_PORT}")
    while True:
        try:
            collect()
        except Exception as e:
            print(f"scrape failed: {e}")
        time.sleep(SCRAPE_INTERVAL)


if __name__ == "__main__":
    main()
