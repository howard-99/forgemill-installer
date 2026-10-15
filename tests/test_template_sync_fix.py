"""Regression tests for the template synchronization FK workaround and source patch.

Run: python3 -m unittest discover -s tests -p test_template_sync_fix.py
All tests use in-memory DBs and temporary files; no ForgeMill data touched.
"""
import importlib.util
from pathlib import Path
import sqlite3
import unittest

ROOT = Path(__file__).resolve().parents[1]

def load_script(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

patcher = load_script("sync_patcher", ROOT / "patches" / "patch-forgemill-template-sync.py")
guard = load_script("sync_guard", ROOT / "fixes" / "repair-template-sync-fk.py")


class SyncFixTests(unittest.TestCase):
    def test_source_patch_requires_unique_vulnerable_block_and_upsert(self):
        src = (
            "package service\nfunc SyncTemplates() {\n"
            + patcher.UNSAFE
            + "stmt := `ON CONFLICT(target_id, moref) DO UPDATE SET`\n"
            + "}\n"
        )
        patched = patcher.patch(src)
        self.assertIn("SYNC-FK-SAFETY", patched)
        self.assertNotIn("DELETE FROM templates", patched)
        with self.assertRaises(ValueError):
            patcher.patch(patched)
        with self.assertRaises(ValueError):
            patcher.patch("not the vulnerable upstream version")

    def test_fk_guard_preserves_referenced_template_ids(self):
        db = sqlite3.connect(":memory:")
        db.execute("PRAGMA foreign_keys=ON")
        db.executescript("""
            CREATE TABLE templates (
                id INTEGER PRIMARY KEY,
                target_id INTEGER NOT NULL,
                moref TEXT NOT NULL,
                managed_by_forgemill INTEGER,
                UNIQUE(target_id, moref)
            );
            CREATE TABLE deployments (
                id INTEGER PRIMARY KEY,
                template_id INTEGER REFERENCES templates(id)
            );
            CREATE TABLE template_builds (
                id INTEGER PRIMARY KEY,
                template_id INTEGER REFERENCES templates(id)
            );
            INSERT INTO templates VALUES
                (1,1,'2',1),
                (8,1,'5',0),
                (9,1,'6',0),
                (10,1,'7',0);
            INSERT INTO deployments VALUES (101,8),(102,9);
            INSERT INTO template_builds VALUES (201,1);
        """)
        clauses = guard.foreign_key_guards(db)
        self.assertEqual(len(clauses), 2)
        db.execute(guard.sql_for(1, clauses))
        db.execute("""
            DELETE FROM templates
            WHERE target_id=1
                AND (managed_by_forgemill=FALSE OR managed_by_forgemill IS NULL)
        """)
        db.execute("""
            INSERT INTO templates(target_id,moref,managed_by_forgemill)
            VALUES (1,'5',0)
            ON CONFLICT(target_id,moref) DO UPDATE SET
                managed_by_forgemill=excluded.managed_by_forgemill
        """)
        self.assertEqual(db.execute("SELECT id FROM templates ORDER BY id").fetchall(),
                         [(1,), (8,), (9,)])
        self.assertEqual(db.execute("PRAGMA foreign_key_check").fetchall(), [])
        db.close()

    def test_guard_does_not_touch_other_target(self):
        db = sqlite3.connect(":memory:")
        db.execute("PRAGMA foreign_keys=ON")
        db.executescript("""
            CREATE TABLE templates (id INTEGER PRIMARY KEY,target_id INTEGER,managed_by_forgemill INTEGER);
            CREATE TABLE deployments (id INTEGER PRIMARY KEY,template_id INTEGER REFERENCES templates(id));
            INSERT INTO templates VALUES (10,2,0);
            INSERT INTO deployments VALUES (20,10);
        """)
        db.execute(guard.sql_for(1, guard.foreign_key_guards(db)))
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("DELETE FROM templates WHERE id=10")
        self.assertEqual(db.execute("SELECT COUNT(*) FROM templates").fetchone()[0], 1)
        db.close()


if __name__ == "__main__":
    unittest.main()
