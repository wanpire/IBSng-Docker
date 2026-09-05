#!/usr/bin/env bash
#
# ═══════════════════════════════════════════════════════════════
#  IBSng — Day-2 Operations Menu
#
#  Run:  sudo bash ibsng-ops.sh
#
#  Companion to ibsng-manager.sh (install/status/logs/restart/update/
#  delete) — this one covers the routine maintenance operations
#  documented in RUNBOOK.md. Every action below implements that
#  document's exact commands and safety checks; RUNBOOK.md is the
#  source of truth if the two ever disagree, not this script.
# ═══════════════════════════════════════════════════════════════

set -uo pipefail
# NOT -e: several checks below (grep/ss for something that may
# legitimately not be there yet, e.g. no cert issued) are expected to
# "fail" as part of normal control flow, not as a fatal error.

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;36m'; N='\033[0m'
ok()   { echo -e "${G}✅ $1${N}"; }
info() { echo -e "${B}ℹ️  $1${N}"; }
warn() { echo -e "${Y}⚠️  $1${N}"; }
err()  { echo -e "${R}❌ $1${N}"; }

CONTAINER="ibsng"
DB="IBSng"
MANUAL_BACKUP_DIR="/root/backups/manual"
LETSENCRYPT_DIR="/etc/letsencrypt"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "Run this as root (sudo bash ibsng-ops.sh)."
        exit 1
    fi
}

pause() { echo ""; read -rp "$(echo -e "${Y}Press Enter to continue...${N}")" _; }

container_exists()  { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
container_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

require_container() {
    if ! container_running "$CONTAINER"; then
        err "Container '$CONTAINER' is not running — nothing to operate on."
        warn "Use ibsng-manager.sh to install or start it first."
        pause
        return 1
    fi
    return 0
}

# ── shared building blocks (RUNBOOK.md §2) ───────────────────────────
daemon_pid_alive() {
    docker exec "$CONTAINER" bash -c \
        'p=$(cat /var/run/IBSng.pid 2>/dev/null); [ -n "$p" ] && ps -p "$p" >/dev/null 2>&1' \
        2>/dev/null
}

stop_daemon() {
    info "Sending SIGTERM to the core daemon..."
    docker exec "$CONTAINER" bash -c 'kill -TERM $(cat /var/run/IBSng.pid) 2>/dev/null; sleep 3'
    if docker exec "$CONTAINER" ss -tlnp 2>/dev/null | grep -q ':1235'; then
        warn "Port 1235 still bound after SIGTERM — finding and force-killing the real PID."
        local real_pid
        real_pid=$(docker exec "$CONTAINER" bash -c "ps aux | grep '[i]bs\.py' | awk '{print \$2}'" | head -1)
        if [ -n "$real_pid" ]; then
            docker exec "$CONTAINER" bash -c "kill -9 ${real_pid}"
            sleep 2
        fi
    fi
    if docker exec "$CONTAINER" ss -tlnp 2>/dev/null | grep -q ':1235'; then
        err "Could not free port 1235 — refusing to continue. Investigate manually before retrying."
        return 1
    fi
    ok "Daemon stopped, port 1235 free."
}

start_daemon() {
    info "Relaunching the core daemon (detached, output redirected — never a TTY)..."
    docker exec -d "$CONTAINER" bash -c \
        "python2.7 /usr/local/IBSng/ibs.py >> /var/log/IBSng/ibs_stdout.log 2>&1"
    sleep 3
    if docker exec "$CONTAINER" tail -10 /var/log/IBSng/ibs_debug.log 2>/dev/null | grep -q "IBS successfully started"; then
        ok "IBS successfully started."
        return 0
    else
        err "Could not confirm 'IBS successfully started.' — recent log:"
        docker exec "$CONTAINER" tail -20 /var/log/IBSng/ibs_debug.log 2>/dev/null
        echo ""
        warn "Also check the full traceback log if this was a crash, not a clean stop:"
        docker exec "$CONTAINER" tail -30 /var/log/IBSng/ibs_stdout.log 2>/dev/null
        return 1
    fi
}

# ── 1) Restart core daemon ────────────────────────────────────────────
op_restart_daemon() {
    require_container || return
    echo ""
    info "This is RUNBOOK.md §2: graceful stop, verify port 1235 free, relaunch detached."
    stop_daemon && start_daemon
    pause
}

# ── 2) Restart web server ─────────────────────────────────────────────
op_restart_web() {
    require_container || return
    echo ""
    echo "  1) apache2ctl graceful  (default — preserves in-flight connections,"
    echo "                           what actually applies a renewed TLS cert)"
    echo "  2) apache2ctl restart   (full stop/start — use only if graceful didn't help)"
    echo ""
    local ch
    read -rp "$(echo -e "${Y}Choice [1]: ${N}")" ch
    ch="${ch:-1}"
    case "$ch" in
        1) info "Running apache2ctl graceful..."
           docker exec "$CONTAINER" apache2ctl graceful && ok "Apache reloaded gracefully." ;;
        2) info "Running apache2ctl restart..."
           docker exec "$CONTAINER" apache2ctl restart && ok "Apache restarted." ;;
        *) warn "Invalid choice, nothing done." ;;
    esac
    pause
}

# ── 3) Status ──────────────────────────────────────────────────────────
op_status() {
    echo ""
    info "RUNBOOK.md §1 — container, ports, panel, daemon pid, all together."
    echo ""
    echo -e "${B}Container:${N}"
    if container_exists "$CONTAINER"; then
        docker ps -a --filter "name=^/${CONTAINER}\$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    else
        err "Container '$CONTAINER' does not exist."
        pause; return
    fi

    if ! container_running "$CONTAINER"; then
        warn "Container is not running — skipping the in-container checks below."
        pause; return
    fi

    echo ""
    echo -e "${B}Ports listening inside the container:${N}"
    docker exec "$CONTAINER" ss -tlnp 2>/dev/null | grep -E ':1235|:80 |:443' || warn "None of 1235/80/443 are listening."
    docker exec "$CONTAINER" ss -ulnp 2>/dev/null | grep -E ':1812|:1813' || warn "Neither RADIUS port (1812/1813) is listening."

    echo ""
    echo -e "${B}Admin panel HTTP status:${N}"
    local http_line
    http_line=$(docker exec "$CONTAINER" wget -qS -O /dev/null http://127.0.0.1/IBSng/admin/ 2>&1 | grep 'HTTP/')
    if echo "$http_line" | grep -q '200'; then
        ok "Panel responding: ${http_line# }"
    else
        err "Panel not responding as expected: ${http_line:-<no response>}"
    fi

    echo ""
    echo -e "${B}Core daemon PID:${N}"
    local pid
    pid=$(docker exec "$CONTAINER" cat /var/run/IBSng.pid 2>/dev/null)
    if [ -z "$pid" ]; then
        err "No PID file — daemon does not appear to have been started."
    elif daemon_pid_alive; then
        ok "PID ${pid} is running: $(docker exec "$CONTAINER" bash -c "ps -p ${pid} -o cmd --no-headers" 2>/dev/null)"
    else
        err "PID file says ${pid}, but no such process is running — the container is Up but the daemon has crashed. Use option 1 to restart it."
    fi
    pause
}

# ── 4) Clear cache & logs ─────────────────────────────────────────────
op_clear_cache_logs() {
    require_container || return
    echo ""
    warn "This is RUNBOOK.md §4 — it TRUNCATES connection_log_details,"
    warn "internet_bw_snapshot, connection_log, and internet_onlines_snapshot"
    warn "on THIS server's live database, and clears IBSng's own log files."
    local c
    read -rp "$(echo -e "${Y}Proceed? (y/n): ${N}")" c
    [ "$c" != "y" ] && { warn "Cancelled."; pause; return; }

    stop_daemon || { pause; return; }

    info "Truncating log tables..."
    local truncate_out
    truncate_out=$(docker exec "$CONTAINER" su postgres -c \
        "psql -d $DB -c 'TRUNCATE connection_log_details, internet_bw_snapshot, connection_log, internet_onlines_snapshot;'" 2>&1)
    echo "$truncate_out"

    start_daemon

    local size_before size_after
    size_before=$(docker exec "$CONTAINER" du -sh /var/log/IBSng 2>/dev/null | awk '{print $1}')
    docker exec "$CONTAINER" bash -c 'find /var/log/IBSng -type f -exec truncate -s 0 {} \;'
    size_after=$(docker exec "$CONTAINER" du -sh /var/log/IBSng 2>/dev/null | awk '{print $1}')

    echo ""
    ok "Done. Log tables truncated; /var/log/IBSng size: ${size_before:-?} → ${size_after:-?}."
    pause
}

# ── 5) Manual backup ──────────────────────────────────────────────────
op_manual_backup() {
    require_container || return
    echo ""
    info "RUNBOOK.md §6 — pg_dump to a host-side timestamped file."
    mkdir -p "$MANUAL_BACKUP_DIR"
    local ts out
    ts=$(date +%Y%m%d_%H%M%S)
    out="${MANUAL_BACKUP_DIR}/ibsng_manual_${ts}.sql"
    docker exec "$CONTAINER" su postgres -c "pg_dump $DB" > "$out"

    local lines copies size
    lines=$(wc -l < "$out")
    copies=$(grep -c '^COPY' "$out")
    size=$(du -h "$out" | awk '{print $1}')

    if [ "$copies" -eq 0 ] || [ ! -s "$out" ]; then
        err "Dump looks empty or invalid (0 COPY statements) — do not trust this file."
    else
        ok "Backup OK: ${out}"
        echo "   ${lines} lines, ${copies} COPY statements, ${size}"
    fi
    pause
}

# ── 6) Restore a backup ⚠️ destructive ────────────────────────────────
op_restore_backup() {
    require_container || return
    echo ""
    warn "RUNBOOK.md §5 — this is destructive. Listing available backup files:"
    echo ""
    local -a files
    mapfile -t files < <(find /root/backups -maxdepth 3 -iname '*.sql' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | awk '{print $2}')
    if [ "${#files[@]}" -eq 0 ]; then
        err "No .sql backup files found under /root/backups."
        pause; return
    fi
    local i=1
    for f in "${files[@]}"; do
        printf "  %2d) %s  (%s, %s)\n" "$i" "$f" "$(date -r "$f" '+%Y-%m-%d %H:%M')" "$(du -h "$f" | awk '{print $1}')"
        i=$((i+1))
    done
    echo ""
    local choice
    read -rp "$(echo -e "${Y}Pick a file by number (or blank to cancel): ${N}")" choice
    [ -z "$choice" ] && { warn "Cancelled."; pause; return; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#files[@]}" ]; then
        err "Invalid selection."; pause; return
    fi
    local dump="${files[$((choice-1))]}"

    echo ""
    err "This will PERMANENTLY DELETE everything currently in the '$DB' database"
    err "on THIS server ($(hostname)) and replace it with:"
    echo "   ${dump}"
    echo ""
    local phrase
    read -rp "$(echo -e "${Y}Type the word restore to continue, anything else cancels: ${N}")" phrase
    if [ "$phrase" != "restore" ]; then
        warn "Cancelled — confirmation phrase did not match."
        pause; return
    fi

    info "Terminating connections to ${DB}..."
    docker exec "$CONTAINER" su postgres -c \
        "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB}' AND pid <> pg_backend_pid();\""

    stop_daemon || { pause; return; }

    local remaining
    remaining=$(docker exec "$CONTAINER" su postgres -c \
        "psql -tAc \"SELECT count(*) FROM pg_stat_activity WHERE datname='${DB}';\"" | tr -d '[:space:]')
    if [ "${remaining:-1}" -ne 0 ]; then
        err "${remaining} connection(s) still open — refusing to drop. Nothing was changed."
        pause; return
    fi

    info "Dropping and recreating ${DB}..."
    docker exec "$CONTAINER" su postgres -c "dropdb ${DB}" || { err "dropdb failed — stopping before restore."; pause; return; }
    docker exec "$CONTAINER" su postgres -c "createdb ${DB}" || { err "createdb failed. ${DB} does not exist right now — needs manual recovery."; pause; return; }
    docker exec "$CONTAINER" su postgres -c "createlang plpgsql ${DB}" 2>&1 | grep -v "already installed" || true

    info "Restoring ${dump}..."
    docker cp "$dump" "$CONTAINER":/tmp/restore.sql
    local restore_out error_count
    restore_out=$(docker exec "$CONTAINER" su postgres -c "psql -d ${DB} -f /tmp/restore.sql" 2>&1)
    error_count=$(printf '%s' "$restore_out" | grep -ci "already exists\|duplicate key\|violates" || true)
    if [ "$error_count" -ne 0 ]; then
        err "Restore produced ${error_count} error(s) — NOT restarting the daemon on unverified data."
        echo "$restore_out" | grep -i "already exists\|duplicate key\|violates" | head -20
        pause; return
    fi
    ok "Restore clean — 0 already-exists/duplicate-key/violates errors."

    info "Transferring ownership to ibs..."
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

    docker exec "$CONTAINER" rm -f /tmp/restore.sql
    start_daemon
    ok "Restore complete."
    pause
}

# ── 7) SSL certificate status ─────────────────────────────────────────
op_ssl_status() {
    echo ""
    info "RUNBOOK.md §8."
    if ! command -v certbot >/dev/null 2>&1; then
        err "certbot is not installed on this host."
        pause; return
    fi
    echo -e "${B}certbot certificates:${N}"
    certbot certificates 2>/dev/null
    echo ""

    local domain
    domain=$(find "${LETSENCRYPT_DIR}/live" -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
        | grep -v 'README' | head -1 | xargs -r basename)
    if [ -z "$domain" ]; then
        warn "No domain found under ${LETSENCRYPT_DIR}/live — no cert issued on this host yet."
        pause; return
    fi
    echo -e "${B}Live cert check for ${domain} (auto-detected from this host):${N}"
    echo | openssl s_client -connect "${domain}:443" -servername "${domain}" 2>/dev/null \
        | openssl x509 -noout -issuer -dates -subject 2>&1
    pause
}

# ── 8) View logs ───────────────────────────────────────────────────────
op_view_logs() {
    while true; do
        echo ""
        echo -e "${B}Logs (RUNBOOK.md §9)${N}"
        echo "  1) Core daemon — lifecycle (ibs_debug.log)"
        echo "  2) Core daemon — full tracebacks (ibs_stdout.log)"
        echo "  3) Apache — errors"
        echo "  4) Apache — SSL errors"
        echo "  5) PHP fatals"
        echo "  6) Postgres"
        echo "  7) Periodic backup/sync (Active only, host-side)"
        echo "  8) Certbot (host-side)"
        echo "  9) Back"
        echo ""
        local ch
        read -rp "$(echo -e "${Y}Choice: ${N}")" ch
        local incontainer="" hostpath=""
        case "$ch" in
            1) incontainer="/var/log/IBSng/ibs_debug.log" ;;
            2) incontainer="/var/log/IBSng/ibs_stdout.log" ;;
            3) incontainer="/var/log/apache2/error.log" ;;
            4) incontainer="/var/log/apache2/ssl_error.log" ;;
            5) incontainer="/var/log/php5/error.log" ;;
            6) incontainer="/var/log/postgresql/postgresql.log" ;;
            7) hostpath="/var/log/ibsng-sync.log" ;;
            8) hostpath="/var/log/letsencrypt/letsencrypt.log" ;;
            9) return ;;
            *) warn "Invalid choice."; continue ;;
        esac

        local mode
        read -rp "$(echo -e "${Y}Follow live (f) or last 50 lines (n)? [n]: ${N}")" mode
        mode="${mode:-n}"
        echo ""
        if [ -n "$incontainer" ]; then
            require_container || continue
            if [ "$mode" = "f" ]; then
                info "Following ${incontainer} inside the container — Ctrl+C to stop."
                docker exec "$CONTAINER" tail -F "$incontainer"
            else
                docker exec "$CONTAINER" tail -n 50 "$incontainer" 2>&1 || warn "Could not read ${incontainer} (may not exist yet)."
            fi
        else
            if [ "$mode" = "f" ]; then
                info "Following ${hostpath} — Ctrl+C to stop."
                tail -F "$hostpath"
            else
                tail -n 50 "$hostpath" 2>&1 || warn "Could not read ${hostpath} (may not exist yet)."
            fi
        fi
        pause
    done
}

main_menu() {
    while true; do
        clear
        echo -e "${B}═══════════════════════════════════════════════${N}"
        echo -e "${B}  IBSng — Operations Menu${N}"
        echo -e "${B}═══════════════════════════════════════════════${N}"
        echo ""
        if container_running "$CONTAINER"; then
            echo -e "  State:   ${G}running${N}"
        elif container_exists "$CONTAINER"; then
            echo -e "  State:   ${Y}stopped${N}"
        else
            echo -e "  State:   ${R}not installed${N}"
        fi
        echo ""
        echo "  1) Restart IBSng core daemon (RADIUS + XML-RPC)"
        echo "  2) Restart web server (Apache)"
        echo "  3) Status (containers, ports, daemon pid, panel reachability)"
        echo "  4) Clear cache & logs (truncates log tables + cleans /var/log/IBSng)"
        echo "  5) Take a manual backup"
        echo "  6) Restore a backup (⚠️  destructive — confirms before running)"
        echo "  7) Check SSL certificate status"
        echo "  8) View logs (submenu: daemon / apache / php / postgres / backup-sync)"
        echo "  9) Back to main manager"
        echo "  x) Exit"
        echo ""
        read -rp "Select: " ch
        case "$ch" in
            1) op_restart_daemon ;;
            2) op_restart_web ;;
            3) op_status ;;
            4) op_clear_cache_logs ;;
            5) op_manual_backup ;;
            6) op_restore_backup ;;
            7) op_ssl_status ;;
            8) op_view_logs ;;
            9) echo ""; info "Run 'sudo bash ibsng-manager.sh' for install/update/delete."; exit 0 ;;
            x|X) echo ""; ok "Bye."; exit 0 ;;
            *) warn "Invalid choice."; sleep 1 ;;
        esac
    done
}

require_root
if [ -t 1 ] && [ -e /dev/tty ]; then
    exec < /dev/tty
fi
main_menu
