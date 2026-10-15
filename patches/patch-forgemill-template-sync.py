#!/usr/bin/env python3
"""Patch upstream ForgeMill SyncTemplates without changing its DB schema.

The upstream service currently DELETEs all unmanaged templates and then
upserts them. That DELETE fails with SQLite FK 787 when historical deployments
reference one of those templates, and recreating IDs would lose history.

Safer interim policy: keep all existing template rows, upsert only by
(target_id, moref). No implicit pruning of stale templates until the application
can perform a separate dependency-aware, audited cleanup.
"""
from __future__ import annotations

import argparse
from pathlib import Path

UNSAFE = '''\t// Only delete templates that are NOT managed by Forgemill Factory
\tif _, err := tx.Exec(`DELETE FROM templates WHERE target_id = ? AND (managed_by_forgemill = FALSE OR managed_by_forgemill IS NULL)`, id); err != nil {
\t\treturn 0, fmt.Errorf("clear unmanaged templates: %w", err)
\t}
'''

SAFE = '''\t// SYNC-FK-SAFETY: NEVER delete a template during inventory synchronization.
\t// Even an unmanaged template may be referenced by deployments, blueprints,
\t// builds or other history. Deleting it violates FK constraints and destroys
\t// stable template IDs. The upsert below refreshes matching target_id+moref
\t// records in place, preserving IDs, metadata and all historical references.
\t// Stale templates are intentionally retained. A future dependency-aware,
\t// explicitly audited cleanup may prune only proven-unreferenced entries.
'''

def patch(source: str) -> str:
    if 'SYNC-FK-SAFETY:' in source:
        raise ValueError("Source already contains SYNC-FK-SAFETY; refusing second patch")
    if source.count(UNSAFE) != 1:
        raise ValueError("Expected vulnerable SyncTemplates deletion block exactly once")
    if "ON CONFLICT(target_id, moref) DO UPDATE SET" not in source:
        raise ValueError("Required template UPSERT not found; aborting")
    result = source.replace(UNSAFE, SAFE, 1)
    if "clear unmanaged templates:" in result:
        raise ValueError("Unpatched cleanup error string remains")
    return result

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("file", type=Path, help="upstream internal/service/target.go")
    args = parser.parse_args()
    original = args.file.read_text(encoding="utf-8")
    revised = patch(original)
    args.file.write_text(revised, encoding="utf-8")
    print(f"PATCHED {args.file}: preserve template IDs and history during sync")
    print("NOTE: stale inventory templates will not be automatically removed")

if __name__ == "__main__":
    main()
