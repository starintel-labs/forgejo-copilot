#!/usr/bin/env python3
"""One-time, audited v1 flat-booking migration; never change the provider's $5 limit."""
import argparse
import hashlib
import json
import sqlite3
import subprocess
import sys
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "deploy"))
from gateway import check_key, provider_floor_cents


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    root = Path.home() / ".local/state/forgejo-copilot"
    key = (Path.home() / ".config/openrouter/forgejo-copilot-key").read_text().strip()
    data = check_key(key)
    floor = provider_floor_cents(data)
    day = datetime.now(timezone.utc).date().isoformat()
    with closing(sqlite3.connect(root / "gateway/budget.sqlite3")) as db, db:
        db.execute("BEGIN IMMEDIATE")
        recorded = db.execute("SELECT cents FROM budget WHERE day=?", (day,)).fetchone()[0]
        count, charged, pending = db.execute("SELECT count(*),coalesce(sum(charged),0),coalesce(sum(charged IS NULL),0) FROM attempts WHERE day=?", (day,)).fetchone()
        legacy = recorded - charged
        print(json.dumps({"day": day, "recorded_cents": recorded, "tracked_upper_bound_cents": charged,
                          "legacy_flat_bookings_cents": legacy, "provider_confirmed_cents_rounded_up": floor,
                          "tracked_requests": count, "unsettled_requests": pending}))
        if not args.apply:
            return
        if pending or legacy <= 0 or legacy % 25:
            raise ValueError("Not an unambiguous fully-settled v1 flat-booking migration")
        for unit in ("forgejo-copilot.service", "forgejo-copilot-worker.service"):
            if subprocess.run(["systemctl", "--user", "is-active", "--quiet", unit]).returncode == 0:
                raise ValueError("Quiesce controller and worker before migration")
        for role in ("review", "task", "task-check", "discord"):
            active = subprocess.check_output(["docker", "ps", "-q", "--filter", "label=actor=forgejo-copilot-" + role], text=True)
            if active.strip():
                raise ValueError("An untrusted agent/check is still active")
        new_total = max(charged, floor)
        snapshot = json.dumps({k: data.get(k) for k in ("limit", "limit_reset", "include_byok_in_limit", "usage_daily", "byok_usage_daily", "limit_remaining")}, sort_keys=True)
        digest = hashlib.sha256(snapshot.encode()).hexdigest()
        db.execute("CREATE TABLE IF NOT EXISTS migrations(day TEXT PRIMARY KEY, old_cents INTEGER,new_cents INTEGER,provider_snapshot TEXT,snapshot_sha256 TEXT,written TEXT)")
        db.execute("INSERT INTO migrations VALUES(?,?,?,?,?,?)", (day, recorded, new_total, snapshot, digest, datetime.now(timezone.utc).isoformat()))
        db.execute("UPDATE budget SET cents=? WHERE day=?", (new_total, day))
        print("Migrated closed historical flat bookings to the maximum of tracked conservative charges and live provider spend. Original balance and provider snapshot retained in migrations; no key limit, request evidence or database was deleted.")


if __name__ == "__main__":
    main()
