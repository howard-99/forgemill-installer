"""Regression tests for the opt-in, all-target SQLite FK safety guard."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sqlite3
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "fixes" / "repair-template-sync-fk.py"
SPEC = spec_from_file_location("guard", SCRIPT)
guard = module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


def fixture():
    db = sqlite3.connect(":memory:")
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript("""
        CREATE TABLE targets(id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE templates(
            id INTEGER PRIMARY KEY, target_id INTEGER NOT NULL,
            moref TEXT NOT NULL, name TEXT,
            UNIQUE(target_id, moref)
        );
        CREATE TABLE deployments(
            id INTEGER PRIMARY KEY, template_id INTEGER NOT NULL,
            FOREIGN KEY(template_id) REFERENCES templates(id)
        );
        CREATE TABLE template_builds(
            id INTEGER PRIMARY KEY, template_id INTEGER,
            FOREIGN KEY(template_id) REFERENCES templates(id)
        );
        INSERT INTO targets VALUES (1,'ESXi-188'), (2,'ESXi-192');
        INSERT INTO templates VALUES
           (8,1,'vm-8','old-188'), (9,2,'vm-9','old-192'),
           (10,2,'vm-10','unreferenced'), (11,1,'vm-11','unreferenced');
        INSERT INTO deployments VALUES (1,8), (2,9);
        INSERT INTO template_builds VALUES (1,9);
    """)
    return db


class TemplateSyncGuardTests(unittest.TestCase):
    def test_read_only_guard_generation_and_integrity(self):
        with fixture() as db:
            clauses = guard.foreign_key_guards(db)
            self.assertEqual(len(clauses), 2)
            sql = guard.desired_sql(clauses)
            self.assertIn("BEFORE DELETE ON templates", sql)
            self.assertNotIn("OLD.target_id", sql)
            guard.verify(db)

    def test_protects_history_for_both_targets(self):
        with fixture() as db:
            db.execute(guard.desired_sql(guard.foreign_key_guards(db)))
            db.execute("DELETE FROM templates WHERE target_id=1")
            db.execute("DELETE FROM templates WHERE target_id=2")
            ids = [x[0] for x in db.execute("SELECT id FROM templates ORDER BY id")]
            self.assertEqual(ids, [8, 9])
            self.assertEqual(db.execute("PRAGMA foreign_key_check").fetchall(), [])
            # A sync-style UPSERT should keep existing referenced identity.
            db.execute("""
                INSERT INTO templates(id,target_id,moref,name)
                VALUES (100,2,'vm-9','updated-192')
                ON CONFLICT(target_id,moref)
                DO UPDATE SET name=excluded.name
            """)
            self.assertEqual(
                db.execute("SELECT id,name FROM templates WHERE moref='vm-9'").fetchone(),
                (9, "updated-192"),
            )

    def test_legacy_scope_is_detected_for_replacement(self):
        with fixture() as db:
            clauses = guard.foreign_key_guards(db)
            legacy = (
                'CREATE TRIGGER "forgemill_template_sync_fk_guard" '
                'BEFORE DELETE ON templates FOR EACH ROW WHEN OLD.target_id = 1 '
                'AND (' + ' OR '.join(clauses) +
                ') BEGIN SELECT RAISE(IGNORE); END'
            )
            self.assertTrue(guard.approved_existing(legacy, clauses))
            self.assertFalse(guard.approved_existing(
                'CREATE TRIGGER "forgemill_template_sync_fk_guard" BEFORE DELETE ON templates BEGIN SELECT RAISE(IGNORE); END',
                clauses,
            ))

    def test_explicit_transaction_for_atomic_upgrade(self):
        self.assertIn('live.execute("BEGIN IMMEDIATE")', SCRIPT.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
