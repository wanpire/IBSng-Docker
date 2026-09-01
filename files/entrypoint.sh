#!/bin/bash
set -e

PG_VERSION="$(ls /usr/lib/postgresql | head -n1)"
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
PGDATA="/var/lib/postgresql/${PG_VERSION}/main"
PGLOG="/var/log/postgresql/postgresql.log"
INSTALLED_MARKER="/var/lib/postgresql/.ibsng_installed"
ADMIN_PASSWORD="${IBSNG_ADMIN_PASSWORD:-admin}"

log() { echo "[entrypoint] $*"; }
err() { echo "[entrypoint] ERROR: $*" >&2; }

mkdir -p "${PGDATA}" /var/log/postgresql /var/run/postgresql /var/log/IBSng
chown -R postgres:postgres "${PGDATA}" /var/log/postgresql /var/run/postgresql
chown -R www-data:www-data /var/log/IBSng

# an incomplete/corrupted Postgres data dir (e.g. a previous run got
# killed mid-initdb) is cleared so we can re-init cleanly
if [ -n "$(ls -A "${PGDATA}" 2>/dev/null)" ] && { [ ! -f "${PGDATA}/PG_VERSION" ] || [ ! -f "${PGDATA}/pg_hba.conf" ]; }; then
    log "found an incomplete Postgres data directory — clearing it and re-initializing..."
    rm -rf "${PGDATA:?}"/*
fi

if [ ! -f "${PGDATA}/PG_VERSION" ]; then
    log "initializing PostgreSQL data directory..."
    su postgres -c "${PG_BIN}/initdb -D ${PGDATA}" || { err "initdb failed."; exit 1; }
fi

if ! grep -q "^local IBSng ibs trust" "${PGDATA}/pg_hba.conf" 2>/dev/null; then
    log "configuring pg_hba.conf for IBSng..."
    { echo "local IBSng ibs trust"; cat "${PGDATA}/pg_hba.conf"; } > "${PGDATA}/pg_hba.conf.new"
    mv "${PGDATA}/pg_hba.conf.new" "${PGDATA}/pg_hba.conf"
    chown postgres:postgres "${PGDATA}/pg_hba.conf"
fi

# start postgres directly via pg_ctl (bypassing Debian's cluster wrapper,
# which doesn't know about a data dir we initialized ourselves); skip if
# it's already running (e.g. this is a restart of a still-warm container)
if ! su postgres -c "pg_isready -q"; then
    log "starting PostgreSQL..."
    su postgres -c "${PG_BIN}/pg_ctl -D ${PGDATA} -l ${PGLOG} -w -t 60 start" || {
        err "PostgreSQL failed to start. Log:"
        tail -n 50 "${PGLOG}" 2>/dev/null || true
        exit 1
    }
else
    log "PostgreSQL already running."
fi

if [ ! -f "${INSTALLED_MARKER}" ]; then
    log "first run detected — creating database and running IBSng setup..."
    su postgres -c "createdb IBSng" 2>/dev/null || true
    su postgres -c "createuser ibs" 2>/dev/null || true
    su postgres -c "createlang plpgsql IBSng" 2>/dev/null || true

    log "running IBSng's setup.py wizard via expect (curses UI, driven blind)..."
    expect /usr/local/IBSng/scripts/setup.exp "${ADMIN_PASSWORD}" 2>&1 | tee /tmp/setup-wizard.log || true

    touch "${INSTALLED_MARKER}"
    log "IBSng install step attempted. Full transcript: /tmp/setup-wizard.log (docker exec in to read it)."
    log "Default admin login (if it succeeded): system / ${ADMIN_PASSWORD}"
else
    log "IBSng already installed — skipping setup wizard."
fi

log "starting Apache..."
apache2ctl start || { err "Apache failed to start. Log:"; tail -n 50 /var/log/apache2/error.log 2>/dev/null; exit 1; }

log "starting IBSng core daemon..."
# ibs.py double-forks: its own launcher process exits(0) once the real
# daemon (the forked child) confirms it started successfully. We must
# NOT exec into it directly — that would make the short-lived launcher
# PID 1 of the container, and PID 1 exiting kills every process in the
# container's PID namespace, daemon child included. Instead run it as a
# normal foreground command so this script (the real PID 1) survives
# the launcher's exit and adopts the orphaned daemon child, then keep
# the container alive by tailing IBSng's own log file forever.
python2.7 /usr/local/IBSng/ibs.py
IBS_RC=$?
if [ "$IBS_RC" -ne 0 ]; then
    err "IBSng failed to start (launcher exit code ${IBS_RC})."
    exit 1
fi
log "IBSng daemon is running in the background. Tailing logs to keep the container alive..."
touch /var/log/IBSng/ibs_debug.log
exec tail -F /var/log/IBSng/ibs_debug.log
