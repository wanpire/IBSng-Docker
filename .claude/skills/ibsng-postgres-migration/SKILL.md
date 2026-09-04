---
name: ibsng-postgres-migration
description: Use when dumping, restoring, or transferring ownership of an IBSng PostgreSQL database between servers or containers. Covers the exact safe sequence (connection termination before dropdb, ownership transfer to the "ibs" role) established after a real data-corruption incident during manual migration.
---

# IBSng PostgreSQL migration — safe procedure

## Why this exists
A manual migration attempt once skipped terminating open connections
before `dropdb`, which failed silently-ish (dropdb errored, but the
following `createdb`/`psql restore` commands ran anyway against the
**old, non-empty** database, producing a corrupted mix of two datasets
full of `duplicate key` / `foreign key violates` / `already exists`
errors that went unnoticed until much later). This procedure prevents
that failure mode by making the termination step unconditional and by
checking dump output for errors before trusting it.

## Step 1: Dump (read-only, always safe)
```bash
docker exec <container> su postgres -c "pg_dump IBSng" > backup.sql
```
Sanity-check before trusting it:
```bash
wc -l backup.sql          # should be substantial, not near-zero
grep -c "^COPY" backup.sql  # should be > 0
```

## Step 2: Terminate connections BEFORE any drop (never skip this)
```bash
docker exec <container> su postgres -c "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='IBSng' AND pid <> pg_backend_pid();\""
```

## Step 3: Drop and recreate a genuinely empty database
```bash
docker exec <container> su postgres -c "dropdb IBSng"
docker exec <container> su postgres -c "createdb IBSng"
docker exec <container> su postgres -c "createlang plpgsql IBSng"
```
If `dropdb` still errors here, STOP — do not proceed to restore. Find out
why connections are still open rather than forcing through it.

## Step 4: Restore
```bash
docker exec -i <container> su postgres -c "psql IBSng" < backup.sql
```
**Read the output.** On a genuinely empty target database, this should
produce only `CREATE TABLE`, `ALTER TABLE`, `COPY <n>` lines — zero
`ERROR: already exists` / `ERROR: duplicate key` / `ERROR: violates
foreign key constraint`. If you see any of those, the target wasn't
actually empty (step 3 didn't work as expected) — stop and investigate,
don't continue to step 5 with a known-bad dataset.

## Step 5: Transfer ownership to the `ibs` role
This repo's `core/db_conf.py` connects as `DB_USERNAME="ibs"`, but a dump
from a differently-configured source (e.g. the old IRSupp image, which
uses `postgres` as the owner) creates everything owned by `postgres`.
Without this step, the core daemon gets permission errors.
```sql
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
    EXECUTE 'ALTER TABLE public.' || quote_ident(r.tablename) || ' OWNER TO ibs';
  END LOOP;
  FOR r IN SELECT sequencename FROM pg_sequences WHERE schemaname='public' LOOP
    EXECUTE 'ALTER SEQUENCE public.' || quote_ident(r.sequencename) || ' OWNER TO ibs';
  END LOOP;
  FOR r IN SELECT viewname FROM pg_views WHERE schemaname='public' LOOP
    EXECUTE 'ALTER VIEW public.' || quote_ident(r.viewname) || ' OWNER TO ibs';
  END LOOP;
END $$;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ibs;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ibs;
```
Run this via `docker exec -i <container> su postgres -c "psql IBSng"` with
the SQL piped in (heredoc).

## Step 6: Restart the core daemon and verify
See the ibsng-daemon-ops skill for the safe restart procedure — do not
just `docker restart` the whole container as a substitute; verify the
daemon actually reports `IBS successfully started.` in its log, then run
through the PROJECT_BRIEF.md testing checklist (at minimum: load the
admin panel, search a known user by both ID and username, check a group
and a RAS entry) before considering the migration done.

## Non-negotiable
Every one of steps 2–4 targets a database that this specific task is
authorized to modify. Before running step 2 or 3 against ANY database,
confirm out loud which server/database you're about to touch and that
the human has approved modifying *that specific one* — see the
destructive-confirm skill. Never run these steps against a database
described elsewhere as "authoritative", "live", or "do not touch" without
a fresh, explicit go-ahead.
