#!/bin/bash
#
# ═══════════════════════════════════════════════════════════════
#  IBSng — 12-hour cleanup + backup + Active→Passive sync
#
#  Runs on ACTIVE only (via cron, see the crontab line this repo's
#  HA.md documents — do NOT also schedule a separate job on Passive,
#  the restore-onto-Passive half runs from here, over SSH, chained
#  after Active's own dump completes, specifically so the two halves
#  can never race each other on independent cron schedules).
#
#  Mirrors the retired CentOS 6.7 setup's periodic log-table cleanup,
#  adapted for this Docker deployment: gracefully stop the core daemon,
#  truncate the same high-churn log tables the old setup did, restart
#  the daemon, clean the container's own log files, dump the now-
#  cleaned database to a host-side file, ship it to Passive, and
#  restore it there following the exact ibsng-postgres-migration skill
#  procedure (terminate connections before dropdb, verify zero
#  already-exists/duplicate-key errors before trusting the restore,
#  transfer ownership to `ibs`).
#
#  Deliberately does NOT `set -e`: a mid-script silent death on one
#  step (e.g. the SSH connection to Passive dropping) would leave
#  Active's daemon stopped with no log entry explaining why. Every
#  step below checks its own exit status explicitly instead, so a
#  partial failure always produces a clear FATAL/WARNING line in the
#  log rather than just... stopping.
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

LOG=/var/log/ibsng-sync.log
BACKUP_DIR=/root/backups/periodic
KEEP_BACKUPS=14   # 7 days of history at the 12h cadence this runs on
CONTAINER=ibsng
DB=IBSng
PASSIVE_HOST=172.17.2.200
PASSIVE_USER=root
# NOT ibsng_ha_sync -- that key is the OTHER direction (Passive -> Active,
# generated in an earlier session for a different purpose). This script
# runs on Active and needs to reach Passive, so it uses its own
# dedicated key, generated on Active specifically for this script.
SSH_KEY="${HOME}/.ssh/ibsng_active_to_passive_sync"
SSH_OPTS="-i ${SSH_KEY} -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"
TS=$(date +%Y%m%d_%H%M%S)
DUMP_FILE="${BACKUP_DIR}/ibsng_${TS}.sql"

log()  { echo "$(date '+%Y-%m-%d %H:%M:%S %z') [ibsng-sync] $*" | tee -a "$LOG"; }
fail() { log "FATAL: $*"; exit 1; }

mkdir -p "$BACKUP_DIR"
log "=== Starting 12h cleanup+backup+sync cycle ==="

# ── 1. Gracefully stop Active's core daemon ──────────────────────────
log "Stopping IBS core daemon on Active..."
docker exec "$CONTAINER" bash -c 'kill -TERM $(cat /var/run/IBSng.pid) 2>/dev/null; sleep 3'
if docker exec "$CONTAINER" ss -tlnp 2>/dev/null | grep -q ':1235'; then
    log "Port 1235 still bound after SIGTERM — force-killing the real PID."
    REAL_PID=$(docker exec "$CONTAINER" bash -c "ps aux | grep '[i]bs\.py' | awk '{print \$2}'" | head -1)
    [ -n "$REAL_PID" ] && docker exec "$CONTAINER" bash -c "kill -9 ${REAL_PID}"
    sleep 2
fi
if docker exec "$CONTAINER" ss -tlnp 2>/dev/null | grep -q ':1235'; then
    fail "Could not free port 1235 on Active — aborting before touching the database."
fi
log "Daemon stopped, port 1235 free."

# ── 2. Truncate the same high-churn log tables the old CentOS setup did
log "Truncating high-churn log tables on Active..."
TRUNCATE_OUT=$(docker exec "$CONTAINER" su postgres -c \
    "psql -d $DB -c 'TRUNCATE connection_log_details, internet_bw_snapshot, connection_log, internet_onlines_snapshot;'" 2>&1)
TRUNCATE_RC=$?
log "Truncate output: ${TRUNCATE_OUT}"
if [ "$TRUNCATE_RC" -ne 0 ]; then
    log "WARNING: TRUNCATE reported an error — restarting the daemon anyway so Active doesn't stay down, then aborting the rest of this cycle."
    docker exec -d "$CONTAINER" bash -c "python2.7 /usr/local/IBSng/ibs.py >> /var/log/IBSng/ibs_stdout.log 2>&1"
    fail "TRUNCATE failed — see output above. Investigate before the next cycle."
fi

# ── 3. Restart Active's core daemon ──────────────────────────────────
log "Restarting IBS core daemon on Active..."
docker exec -d "$CONTAINER" bash -c "python2.7 /usr/local/IBSng/ibs.py >> /var/log/IBSng/ibs_stdout.log 2>&1"
sleep 3
if docker exec "$CONTAINER" tail -5 /var/log/IBSng/ibs_debug.log 2>/dev/null | grep -q "IBS successfully started"; then
    log "Daemon restarted successfully."
else
    log "WARNING: could not confirm 'IBS successfully started' in the log after restart — check manually. Continuing with the backup regardless, since the DB itself is fine."
fi

# ── 4. Clean IBSng's own log files inside the container ─────────────
# truncate in place (not rm) — the daemon we just restarted and the
# entrypoint's own `tail -F` both hold this file open; removing it
# would silently break `docker logs` output until the next container
# restart while the daemon kept writing to an orphaned, unlinked inode.
log "Truncating /var/log/IBSng/* inside the container (in place, not deleting)..."
docker exec "$CONTAINER" bash -c 'find /var/log/IBSng -type f -exec truncate -s 0 {} \;'

# ── 5. Dump to a host-side file (survives container recreate) ───────
log "Dumping database to ${DUMP_FILE}..."
docker exec "$CONTAINER" su postgres -c "pg_dump $DB" > "$DUMP_FILE" 2>>"$LOG"
if [ ! -s "$DUMP_FILE" ] || ! grep -q '^COPY' "$DUMP_FILE"; then
    fail "Dump at ${DUMP_FILE} looks empty or invalid — aborting before touching Passive. Active's own daemon is already back up and unaffected."
fi
log "Dump OK: $(wc -l < "$DUMP_FILE") lines, $(grep -c '^COPY' "$DUMP_FILE") COPY statements."

# ── 6. Ship the dump to Passive ──────────────────────────────────────
log "Copying dump to Passive (${PASSIVE_HOST})..."
if ! scp $SSH_OPTS "$DUMP_FILE" "${PASSIVE_USER}@${PASSIVE_HOST}:/root/backups/incoming.sql" >>"$LOG" 2>&1; then
    fail "scp to Passive failed — Active's own daemon is already back up, so this is a sync failure only, not an Active outage. Check the ibsng_ha_sync key / network before the next cycle; Passive was NOT touched."
fi
log "Copied to Passive."

# ── 7. Restore onto Passive, following the ibsng-postgres-migration skill
log "Restoring onto Passive..."
ssh $SSH_OPTS "${PASSIVE_USER}@${PASSIVE_HOST}" bash -s <<'REMOTE_SCRIPT' >>"$LOG" 2>&1
set -uo pipefail
CONTAINER=ibsng
DB=IBSng

echo "[passive-restore] Terminating connections to ${DB}..."
docker exec "$CONTAINER" su postgres -c \
    "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB}' AND pid <> pg_backend_pid();\""

echo "[passive-restore] Stopping Passive's core daemon..."
docker exec "$CONTAINER" bash -c 'kill -TERM $(cat /var/run/IBSng.pid) 2>/dev/null; sleep 3'
if docker exec "$CONTAINER" ss -tlnp 2>/dev/null | grep -q ':1235'; then
    REAL_PID=$(docker exec "$CONTAINER" bash -c "ps aux | grep '[i]bs\.py' | awk '{print \$2}'" | head -1)
    [ -n "$REAL_PID" ] && docker exec "$CONTAINER" bash -c "kill -9 ${REAL_PID}"
    sleep 2
fi

echo "[passive-restore] Re-checking for open connections before dropping..."
REMAINING=$(docker exec "$CONTAINER" su postgres -c "psql -tAc \"SELECT count(*) FROM pg_stat_activity WHERE datname='${DB}';\"" | tr -d '[:space:]')
if [ "${REMAINING:-1}" -ne 0 ]; then
    echo "[passive-restore] FATAL: ${REMAINING} connection(s) still open — refusing to drop. Manual intervention needed; Passive's old data is untouched."
    exit 1
fi

echo "[passive-restore] Dropping and recreating ${DB}..."
docker exec "$CONTAINER" su postgres -c "dropdb ${DB}" || { echo "[passive-restore] FATAL: dropdb failed — stopping here rather than restoring into a possibly-non-empty DB."; exit 1; }
docker exec "$CONTAINER" su postgres -c "createdb ${DB}" || { echo "[passive-restore] FATAL: createdb failed. Passive's IBSng DB does not exist right now — needs manual recovery."; exit 1; }
docker exec "$CONTAINER" su postgres -c "createlang plpgsql ${DB}" 2>&1 | grep -v "already installed" || true

echo "[passive-restore] Restoring dump..."
docker cp /root/backups/incoming.sql "$CONTAINER":/tmp/restore.sql
RESTORE_OUT=$(docker exec "$CONTAINER" su postgres -c "psql -d ${DB} -f /tmp/restore.sql" 2>&1)
ERROR_COUNT=$(printf '%s' "$RESTORE_OUT" | grep -ci "already exists\|duplicate key\|violates" || true)
if [ "$ERROR_COUNT" -ne 0 ]; then
    echo "[passive-restore] FATAL: restore produced ${ERROR_COUNT} error(s) (already exists/duplicate key/violates). Target was not actually empty, or the dump is corrupt. NOT restarting the daemon on top of unverified data. Full restore output follows:"
    echo "$RESTORE_OUT"
    exit 1
fi
echo "[passive-restore] Restore clean — 0 already-exists/duplicate-key/violates errors."

echo "[passive-restore] Transferring table/sequence/view ownership to ibs..."
docker exec -i "$CONTAINER" su postgres -c "psql -d ${DB}" <<'SQL'
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
SQL

echo "[passive-restore] Restarting Passive's core daemon..."
docker exec -d "$CONTAINER" bash -c "python2.7 /usr/local/IBSng/ibs.py >> /var/log/IBSng/ibs_stdout.log 2>&1"
sleep 3
if docker exec "$CONTAINER" tail -5 /var/log/IBSng/ibs_debug.log 2>/dev/null | grep -q "IBS successfully started"; then
    echo "[passive-restore] Daemon restarted successfully."
else
    echo "[passive-restore] WARNING: could not confirm daemon restart in the log — check manually."
fi

echo "[passive-restore] Cleaning up remote temp files..."
rm -f /root/backups/incoming.sql
docker exec "$CONTAINER" rm -f /tmp/restore.sql

echo "[passive-restore] Done."
REMOTE_SCRIPT
REMOTE_RC=$?
if [ "$REMOTE_RC" -ne 0 ]; then
    fail "Passive restore step failed (see [passive-restore] lines above). Active is fine and already back up; Passive may be left mid-update. Investigate before the next cycle — do not assume Passive's daemon is running."
fi
log "Passive restore completed successfully."

# ── housekeeping: prune old local dumps ──────────────────────────────
find "$BACKUP_DIR" -maxdepth 1 -name 'ibsng_*.sql' -type f -print 2>/dev/null \
    | sort | head -n -"$KEEP_BACKUPS" | xargs -r rm -f

log "=== Cycle complete ==="
