---
name: destructive-confirm
description: Use before running any command that deletes, drops, truncates, overwrites, or otherwise irreversibly modifies data or infrastructure on the IBSng Active or Passive servers — dropdb, TRUNCATE, restoring a dump over an existing database, docker rm of a container with a data volume, volume deletion, removing the IRSupp container, etc. Also applies to any command run against a server or database described as "live", "authoritative", or "do not touch" in the current task.
---

# Confirm before destructive actions

## The rule
Before running any of the following against either server, stop and ask
the human for an explicit, specific go-ahead — naming the exact server,
database, and command you're about to run. Do not proceed on the basis
of an earlier, more general approval, and do not proceed just because a
similar-looking command was run successfully elsewhere in this project.

Commands/actions this applies to:
- `dropdb`, `DROP TABLE`, `DROP DATABASE`
- `TRUNCATE` on any table
- `psql ... < dump.sql` restore into a database that isn't freshly created/empty
- `docker rm` / `docker rm -f` of any container attached to a data volume
- `docker volume rm`
- Removing or stopping the IRSupp container on Passive
- Any `rm -rf` touching `/var/lib/postgresql`, `/usr/local/IBSng`, or a
  Docker volume mount point
- Overwriting `entrypoint.sh`, `Dockerfile`, or other files in a way that
  would require a rebuild that disrupts a currently-running production container

## Why this exists
A manual migration on this project once ran a `dropdb` that failed due to
open connections, then continued running `createdb`/restore commands
against what was actually still the old, non-empty database — producing
a corrupted mixed dataset that wasn't caught until much later, because
each individual step "looked like" it was progressing normally. The fix
adopted was to make connection-termination unconditional (see the
ibsng-postgres-migration skill) — but the deeper lesson is: **don't chain
destructive steps under a single earlier approval, and don't assume a
step succeeded just because it didn't throw a fatal error** — check its
actual output.

## What "confirm" means in practice
State plainly: "I'm about to run `<exact command>` against `<server IP>`,
which will `<precise consequence — e.g. 'permanently delete all data
currently in Passive's IBSng database'>`. Confirm before I proceed?" and
wait for an explicit yes. A general instruction like "go ahead and set
this up" given earlier in the conversation does not count as confirmation
for a specific destructive step reached later — ask again at the moment
you're about to run it.

## Exception
Read-only operations (`pg_dump`, `SELECT`, `docker ps`, `docker logs`,
`cat`, `grep`) never need this — don't over-ask for things that can't
cause harm. The point is to gate irreversible actions, not to slow down
routine investigation.
