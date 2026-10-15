#!/usr/bin/env python3
"""Opt-in, reversible workaround for ForgeMill sync foreign-key error 787.

Upstream old releases delete unmanaged templates during sync, even when
historical deployment/build records refer to them. Install a SQLite BEFORE
DELETE trigger that silently SKIPS only those deletes which would violate a
known template foreign key. This does not change or delete any existing rows.

Use only until patched application image is deployed.
Run with the ForgeMill container STOPPED.
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

def docker_running() -> bool:
    check = subprocess.run(
        ["docker", "inspect", "--format", "{{.State.Running}}", "forgemill"],
        capture_output=True, text=True, check=False
    )
    return check.returncode == 0 and check.stdout.strip().lower() == "true"

def foreign_key_guards(db: sqlite3.Connection) -> list[str]:
    tables = [x[0] for x in db.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    )]
    clauses: list[str] = []
    for table in tables:
        groups: dict[int, list] = {}
        for row in db.execute("PRAGMA foreign_key_list(" + qi(table) + ")"):
            if row[2] == "templates":
                groups.setdefault(row[0], []).append(row)
        for rows in groups.values():
            if len(rows) != 1:
                raise RuntimeError("Composite FK to templates found in " + table + "; cannot install safeguard")
            fk = rows[0]
            if fk[4] not in ("", "id", None):
                raise RuntimeError("Non-id reference to templates found in " + table)
            clauses.append(
                f"EXISTS (SELECT 1 FROM {qi(table)} WHERE {qi(fk[3])} = OLD.id)"
            )
    return clauses

def sql_for(target_id: int, clauses: list[str]) -> str:
    if not clauses:
        raise RuntimeError("No template FK relationships found; inspect schema first")
    return (
        f"CREATE TRIGGER {qi(NAME)} BEFORE DELETE ON templates FOR EACH ROW "
        f"WHEN OLD.target_id = {target_id} AND (" + " OR ".join(clauses) +
        ") BEGIN SELECT RAISE(IGNORE); END"
    )

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--apply", action="store_true", help="Backup and install temporary trigger")
    group.add_argument("--remove", action="store_true", help="Backup and remove temporary trigger")
    parser.add_argument("--target-id", type=int, default=1)
    args = parser.parse_args()
    if args.target_id <= 0:
        parser.error("target ID must be positive")
    if not SOURCE.is_file():
        raise RuntimeError(f"Missing DB {SOURCE}")
    if os.geteuid() != 0:
        raise RuntimeError("Run as root on the ForgeMill Ubuntu host")
    if docker_running() and (args.apply or args.remove):
        raise RuntimeError("Stop ForgeMill container before modifying database")

    uri = "file:" + str(SOURCE) + "?mode=ro"
    with sqlite3.connect(uri, uri=True) as db:
        clauses = foreign_key_guards(db)
        existing = db.execute(
            "SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?",
            (NAME,),
        ).fetchone()
        print("Integrity:", db.execute("PRAGMA integrity_check").fetchone()[0])
        print("Template FK guards:", len(clauses))
        print("Guard installed:", bool(existing))
        print("Target:", args.target_id)
        rows = db.execute(
            """SELECT t.id,t.name,t.moref,
               (SELECT COUNT(*) FROM deployments d WHERE d.template_id=t.id)
               FROM templates t WHERE t.target_id=?
               ORDER BY t.id""", (args.target_id,),
        ).fetchall()
        for row in rows:
            print("Template:", *row)

        if not args.apply and not args.remove:
            print("READ ONLY. Stop the container and run --apply for temporary protection.")
            return 0
        if args.apply and existing:
            print("Existing guard found; no changes. To remove later use --remove.")
            return 0
        if args.remove and not existing:
            print("Guard absent; nothing to remove.")
            return 0

        os.umask(0o077)
        BACKUP_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        backup = BACKUP_DIR / f"template-sync-guard-{timestamp}.db"
        with sqlite3.connect(str(backup)) as dst:
            db.backup(dst)
        os.chmod(backup, 0o600)
        with sqlite3.connect(str(backup)) as verify:
            if verify.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise RuntimeError("Backup integrity failed")
        print("Verified backup:", backup)

    original = SOURCE.stat()
    with sqlite3.connect(str(SOURCE), timeout=30) as db:
        db.execute("PRAGMA foreign_keys=ON")
        if args.apply:
            db.execute(sql_for(args.target_id, clauses))
            print("Installed temporary FK-safe sync guard")
        else:
            db.execute(f"DROP TRIGGER {qi(NAME)}")
            print("Removed temporary FK-safe sync guard")
        db.commit()
        result = db.execute("PRAGMA integrity_check").fetchone()[0]
        if result != "ok":
            raise RuntimeError("Post-change integrity failure: " + result)
        print("Post-change integrity:", result)

    # SQLite WAL / SHM files created by root must stay accessible to the
    # original unprivileged container UID. Restore owner for any such files.
    for suffix in ("", "-wal", "-shm"):
        file = Path(str(SOURCE) + suffix)
        if file.exists():
            os.chown(file, original.st_uid, original.st_gid)
    print("Complete; restart ForgeMill only after successful integrity check.")
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
