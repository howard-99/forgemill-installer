#!/usr/bin/env python3
"""Reversible temporary workaround for ForgeMill template sync FK error (787).

Unpatched ForgeMill deletes unmanaged template rows on every target sync,
even when a deployment/history table references them. This creates a
BEFORE DELETE trigger which skips only those deletes that would break
a declared FK to templates. It protects ALL targets (including targets
added after the fix). It does not alter or delete any existing rows.

This is NOT the permanent application-code patch. Run --apply/--remove
as root on ForgeMill's Ubuntu host with the 'forgemill' Docker container
STOPPED, then restart it once the integrity check completes.

Without --apply or --remove the script is read-only.
"""
from __future__ import annotations

import argparse
import datetime
import os
from pathlib import Path
import sqlite3
import subprocess
import sys

SOURCE = Path("/opt/forgemill/data/forgemill.db")
BACKUP_DIR = Path("/opt/forgemill/backups")
NAME = "forgemill_template_sync_fk_guard"


def qi(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def require_stopped_container() -> None:
    try:
        result = subprocess.run(
            ["docker", "inspect", "--format", "{{.State.Running}}", "forgemill"],
            capture_output=True, text=True, check=False, timeout=15
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError("Cannot verify ForgeMill container is stopped: " + str(exc))
    if result.returncode != 0:
        raise RuntimeError(
            "Cannot inspect ForgeMill container; refusing database modification: "
            + result.stderr.strip()
        )
    state = result.stdout.strip().lower()
    if state != "false":
        raise RuntimeError(
            "Stop ForgeMill container first; docker inspect Running=" + repr(state)
        )


def foreign_key_guards(db: sqlite3.Connection) -> list[str]:
    tables = [
        x[0] for x in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        )
    ]
    clauses: list[str] = []
    for table in tables:
        groups: dict[int, list] = {}
        for row in db.execute("PRAGMA foreign_key_list(" + qi(table) + ")"):
            if row[2] == "templates":
                groups.setdefault(row[0], []).append(row)
        for rows in groups.values():
            if len(rows) != 1:
                raise RuntimeError("Composite FK to templates in " + table + "; aborting")
            fk = rows[0]
            if fk[4] not in ("", "id", None):
                raise RuntimeError("Non-ID reference to templates in " + table + "; aborting")
            clauses.append(
                f"EXISTS (SELECT 1 FROM {qi(table)} WHERE {qi(fk[3])} = OLD.id)"
            )
    if not clauses:
        raise RuntimeError("No declared foreign keys to templates found; aborting")
    return clauses


def desired_sql(clauses: list[str]) -> str:
    return (
        f"CREATE TRIGGER {qi(NAME)} BEFORE DELETE ON templates FOR EACH ROW "
        "WHEN (" + " OR ".join(clauses) +
        ") BEGIN SELECT RAISE(IGNORE); END"
    )


def approved_existing(sql: str, clauses: list[str]) -> bool:
    # Permit only the older target-specific guard from this same installer.
    # Never silently replace arbitrary triggers written by an administrator.
    if "OLD.target_id" not in sql or "RAISE(IGNORE)" not in sql:
        return False
    if "BEFORE DELETE ON templates" not in sql:
        return False
    return all(clause in sql for clause in clauses)


def describe(db: sqlite3.Connection) -> None:
    tables = {
        x[0] for x in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )
    }
    if "targets" in tables:
        cols = {x[1] for x in db.execute("PRAGMA table_info(targets)")}
        if {"id", "name"}.issubset(cols):
            print("ForgeMill targets:")
            for target_id, name in db.execute("SELECT id,name FROM targets ORDER BY id"):
                print("  ", target_id, name)
    if "templates" in tables:
        cols = {x[1] for x in db.execute("PRAGMA table_info(templates)")}
        if {"id", "name", "target_id"}.issubset(cols):
            print("Template rows by target:")
            for tid, num in db.execute(
                "SELECT target_id,COUNT(*) FROM templates GROUP BY target_id ORDER BY target_id"
            ):
                print("  ", tid, num)


def verify(db: sqlite3.Connection) -> None:
    result = db.execute("PRAGMA integrity_check").fetchone()[0]
    if result != "ok":
        raise RuntimeError("SQLite integrity_check failed: " + result)
    violations = db.execute("PRAGMA foreign_key_check").fetchall()
    if violations:
        raise RuntimeError(
            "Existing foreign-key violations detected; refusing change: "
            + repr(violations[:10])
        )
    print("Integrity: ok; foreign_key_check: ok")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--apply", action="store_true",
                         help="Back up SQLite and protect all targets")
    actions.add_argument("--remove", action="store_true",
                         help="Back up SQLite and remove the temporary guard")
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise RuntimeError("Run as root on the ForgeMill Ubuntu host")
    if not SOURCE.is_file():
        raise RuntimeError("Missing ForgeMill database: " + str(SOURCE))
    if args.apply or args.remove:
        require_stopped_container()

    uri = "file:" + str(SOURCE) + "?mode=ro"
    with sqlite3.connect(uri, uri=True, timeout=30) as db:
        verify(db)
        clauses = foreign_key_guards(db)
        current = db.execute(
            "SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?",
            (NAME,),
        ).fetchone()
        wanted = desired_sql(clauses)
        existing_sql = current[0] if current else None
        print("Declared FK guards:", len(clauses))
        print("Installed guard:", "all-target" if existing_sql == wanted else (
            "legacy/other" if existing_sql else "none"))
        describe(db)
        if not args.apply and not args.remove:
            print("READ ONLY. No database changes.")
            return 0
        if args.apply and existing_sql == wanted:
            print("All-target guard already installed; no changes.")
            return 0
        if args.remove and not existing_sql:
            print("No guard installed; no changes.")
            return 0
        if existing_sql and existing_sql != wanted and not approved_existing(existing_sql, clauses):
            raise RuntimeError("Unexpected trigger with same name; refusing to overwrite or remove it")

        os.umask(0o077)
        BACKUP_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        backup = BACKUP_DIR / f"template-sync-guard-{stamp}.db"
        with sqlite3.connect(str(backup)) as dest:
            db.backup(dest)
        os.chmod(backup, 0o600)
        with sqlite3.connect(str(backup)) as bcheck:
            verify(bcheck)
        print("Verified backup:", backup)

    ownership = SOURCE.stat()
    # A single transaction guarantees a scoped-to-global upgrade cannot
    # temporarily leave the database without either guard if it fails.
    with sqlite3.connect(str(SOURCE), timeout=30) as live:
        live.execute("PRAGMA foreign_keys=ON")
        if existing_sql:
            live.execute(f"DROP TRIGGER {qi(NAME)}")
        if args.apply:
            live.execute(wanted)
        verify(live)
        live.commit()
    # Root may have created WAL/SHM sidecars. Restore their original access.
    for suffix in ("", "-wal", "-shm"):
        part = Path(str(SOURCE) + suffix)
        if part.exists():
            os.chown(part, ownership.st_uid, ownership.st_gid)
    print("Guard:", "INSTALLED for all targets" if args.apply else "REMOVED")
    print("Restart the ForgeMill container, then retry Sync Templates.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print("ERROR:", exc, file=sys.stderr)
        sys.exit(1)
