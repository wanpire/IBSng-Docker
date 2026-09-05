# IBSng — Operations Runbook

Day-2 operations for a server already installed via `ibsng-manager.sh`.
Every command below has been run for real against both production
servers (Active `172.17.3.200` / `ibsng.alonet.co`, Passive
`172.17.2.200` / `ibs.alonet.co`) — this isn't a theoretical procedure,
it's what was actually typed and verified working. See `HA.md` for the
full narrative and dates; this document is the distilled reference.

**`ibsng-ops.sh`** (alongside `ibsng-manager.sh` in this repo) wraps
every section below in a menu — prefer it for routine work. The raw
commands stay documented here underneath each section as a fallback,
and so anyone can see exactly what the script does before running it.

Container name is assumed to be `ibsng` throughout (the default both
scripts use). Replace if yours differs.

## §1 Quick status check

> **`ibsng-ops.sh` → option 3.**

Four things, together — a container showing `Up` does **not** mean the
core daemon inside it is healthy; the daemon has crashed while the
container kept running before, so check all four, not just the first.

```bash
# 1. Container itself
docker ps --filter name=ibsng --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# 2. Ports actually listening inside the container
docker exec ibsng ss -tlnp | grep -E ':1235|:80 |:443'
docker exec ibsng ss -ulnp | grep -E ':1812|:1813'

# 3. Admin panel actually responds
docker exec ibsng wget -qS -O /dev/null http://127.0.0.1/IBSng/admin/ 2>&1 | grep 'HTTP/'
# expect: HTTP/1.1 200 OK

# 4. Daemon PID file matches a real, running process
docker exec ibsng cat /var/run/IBSng.pid
docker exec ibsng bash -c 'ps -p $(cat /var/run/IBSng.pid) -o pid,cmd --no-headers'
# empty output here = the pidfile is stale and the daemon is NOT
# actually running, even though the container is "Up" — this exact
# scenario is why this is its own check, not folded into #1
```

## §2 Restarting the core daemon (RADIUS + XML-RPC)

> **`ibsng-ops.sh` → option 1.** Implements every step below, including
> the port-1235-free check and the log confirmation.

`ibs.py` double-forks: the launcher process exits(0) once the forked
child confirms startup. Two known ways to break this:

- **Never** run it attached to a TTY that will later close
  (`docker exec -it ibsng python2.7 ibs.py`) — closing that session
  breaks the daemon's stdout/stderr, and every subsequent request fails
  with a misleading 500 error until it's relaunched correctly.
- **Never** just `pkill` and assume it worked — stale/zombie processes
  have caused "Address already in use" on relaunch before. Confirm the
  port is actually free, and if not, find and kill the *real* PID.

Full sequence:

```bash
# 1. Graceful stop
docker exec ibsng bash -c 'kill -TERM $(cat /var/run/IBSng.pid) 2>/dev/null; sleep 3'

# 2. Verify port 1235 is ACTUALLY free
docker exec ibsng ss -tlnp | grep 1235
# if still bound, find the real PID and kill -9 it specifically:
docker exec ibsng bash -c "ps aux | grep '[i]bs\.py'"
docker exec ibsng bash -c "kill -9 <real_pid>"

# 3. Relaunch — detached, redirected, never attached to a TTY
docker exec -d ibsng bash -c "python2.7 /usr/local/IBSng/ibs.py >> /var/log/IBSng/ibs_stdout.log 2>&1"

# 4. Confirm it actually started
sleep 3
docker exec ibsng tail -10 /var/log/IBSng/ibs_debug.log
# look for "IBS successfully started." — if instead you see a Python
# traceback or nothing new, read /var/log/IBSng/ibs_stdout.log in full
# before assuming anything, don't just retry blindly
```

## §3 Restarting the web server (Apache)

> **`ibsng-ops.sh` → option 2.** Asks which of the two below, doesn't
> pick one silently.

Two options, in order of preference:

- **`apache2ctl graceful`** (default/first choice) — reloads config
  without dropping in-flight connections, and is what actually applies
  a newly-renewed TLS cert (see `HA.md`'s certbot deploy hook — this is
  the exact command it runs). Use this for almost everything: a config
  change, a renewed cert, a hung-seeming request.
- **`apache2ctl restart`** (fallback) — a full stop/start. Use only if
  `graceful` didn't resolve whatever the problem was; it's more
  disruptive (drops in-flight connections) for no benefit in the common
  case.

```bash
docker exec ibsng apache2ctl graceful
# or, if that didn't help:
docker exec ibsng apache2ctl restart
```

Neither of these touches the core daemon (§2) — they're independent.

## §4 Clearing cache & logs (periodic maintenance)

> **`ibsng-ops.sh` → option 4.** Also reports the `/var/log/IBSng`
> size before/after so you can see what was actually reclaimed.

This is the same procedure the 12-hour cron job on Active runs
automatically (`files/ibsng-cleanup-backup-sync.sh`, see `HA.md`) —
useful to run by hand between scheduled cycles, or on Passive (which
isn't on that cron job). Truncates the specific high-churn log tables
the retired CentOS setup used to clear, and only those — not a broader
or different set.

```bash
# 1. Stop the daemon (§2, steps 1-2)
docker exec ibsng bash -c 'kill -TERM $(cat /var/run/IBSng.pid) 2>/dev/null; sleep 3'
docker exec ibsng ss -tlnp | grep 1235   # confirm free, force-kill if not (§2)

# 2. Truncate the log tables
docker exec ibsng su postgres -c \
    "psql -d IBSng -c 'TRUNCATE connection_log_details, internet_bw_snapshot, connection_log, internet_onlines_snapshot;'"

# 3. Restart the daemon (§2, steps 3-4)
docker exec -d ibsng bash -c "python2.7 /usr/local/IBSng/ibs.py >> /var/log/IBSng/ibs_stdout.log 2>&1"
sleep 3
docker exec ibsng tail -10 /var/log/IBSng/ibs_debug.log   # confirm "IBS successfully started."

# 4. Clear IBSng's own log files — truncate IN PLACE, never rm. The
#    daemon (just restarted) and the container's own `tail -F` (keeping
#    it alive) both hold these files open; removing the file instead of
#    truncating it silently breaks `docker logs` output until the next
#    container restart, while the daemon keeps writing to an orphaned,
#    unlinked inode that never actually frees the disk space.
docker exec ibsng bash -c 'find /var/log/IBSng -type f -exec truncate -s 0 {} \;'
```

## §5 Restoring a backup ⚠️ destructive

> **`ibsng-ops.sh` → option 6.** Lists available backup files, requires
> typing the word `restore` to proceed (not just y/n), and checks the
> restore output for errors before declaring success — same as below,
> just driven from a menu instead of typed by hand.

**This permanently deletes everything currently in this server's
`IBSng` database and replaces it with the selected backup file.**
Per the `destructive-confirm` skill: confirm out loud which server
you're about to touch, immediately before running this — a general
"yes, do maintenance" from earlier in a conversation does not count.

Follows the `ibsng-postgres-migration` skill exactly — the sequence
below exists because a manual migration once skipped connection
termination before `dropdb`, which failed silently-ish, and the
restore then ran anyway against what was actually still the old,
non-empty database, producing a corrupted mixed dataset that wasn't
caught until much later.

```bash
DB=IBSng
DUMP=/path/to/backup.sql   # must already exist and look valid — see §6

# 1. Terminate connections BEFORE any drop — never skip this
docker exec ibsng su postgres -c \
    "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB}' AND pid <> pg_backend_pid();\""

# 2. Drop and recreate a genuinely empty database
docker exec ibsng su postgres -c "dropdb ${DB}"
docker exec ibsng su postgres -c "createdb ${DB}"
docker exec ibsng su postgres -c "createlang plpgsql ${DB}"
# if createlang says "already installed" — harmless, this Postgres
# version ships it by default; if dropdb itself errors, STOP — do not
# proceed to restore, find out why connections are still open first

# 3. Restore
docker cp "$DUMP" ibsng:/tmp/restore.sql
docker exec ibsng su postgres -c "psql -d ${DB} -f /tmp/restore.sql" > /tmp/restore_output.log 2>&1
grep -ci "already exists\|duplicate key\|violates" /tmp/restore_output.log
# MUST be 0. On a genuinely empty target this produces only CREATE
# TABLE / ALTER TABLE / COPY <n> lines. Any of those three error types
# means the target wasn't actually empty — stop and investigate, don't
# continue to step 4 with a known-bad dataset.

# 4. Transfer ownership to the `ibs` role (skip if the dump's source
#    already used this repo's `ibs`-owned convention — check first:
#    docker exec ibsng su postgres -c "psql -d ${DB} -c \"SELECT tableowner, count(*) FROM pg_tables WHERE schemaname='public' GROUP BY tableowner;\""
#    — if everything's already `ibs`, this step is a no-op, safe to run
#    anyway)
docker exec -i ibsng su postgres -c "psql -d ${DB}" <<'SQL'
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

# 5. Restart the daemon (§2) and verify (§1) before considering this done
docker exec ibsng rm -f /tmp/restore.sql
```

## §6 Taking a manual backup

> **`ibsng-ops.sh` → option 5.** Runs the sanity check automatically
> and reports lines/COPY-count/size.

```bash
TS=$(date +%Y%m%d_%H%M%S)
OUT="/root/backups/manual/ibsng_manual_${TS}.sql"   # outside the container — survives a recreate
mkdir -p "$(dirname "$OUT")"
docker exec ibsng su postgres -c "pg_dump IBSng" > "$OUT"

# Sanity-check before trusting it — never skip this
wc -l "$OUT"                # should be substantial (thousands of lines), not near-zero
grep -c '^COPY' "$OUT"      # should be > 0 (51 on both production servers as of 2026-09)
```

## §7 Diagnosing "Can't connect to IBS Core" / silent failures

> Not in `ibsng-ops.sh` — this one needs judgment about which method/
> params to test, not a fixed procedure a menu item can drive. Manual
> only, for now.

IBSng's own error handling shows this generic message (or a bare
HTTP 500) for almost **any** XML-RPC fault, not just real connectivity
problems — `interface/xmlrpc/xmlrpc.inc`'s hardcoded wrapper string.
Don't chase network theories first; get the real fault string:

```bash
docker exec -i ibsng bash -c "cat > /tmp/t.php" <<'EOF'
<?php
require("/usr/local/IBSng/interface/xmlrpc/xmlrpc.inc");
$client = new xmlrpc_client("/", "127.0.0.1", 1235);
$msg = new xmlrpcmsg("<method.name>", array(php_xmlrpc_encode(array(/* params matching what the failing PHP page actually sends */))));
$resp = $client->send($msg, 10);
if (!$resp) echo "NO RESPONSE\n";
elseif ($resp->faultCode()) echo "FAULT: " . $resp->faultString() . "\n";
else { echo "SUCCESS\n"; print_r(php_xmlrpc_decode($resp->value())); }
EOF
docker exec -it ibsng php5 /tmp/t.php
```

Find the exact method name/params a failing page sends by reading its
PHP source and tracing back through `interface/IBSng/inc/*.php`'s
`Request`-derived classes (each wraps one `core.<method>` call — check
the constructor). Cross-reference the fault string against `core/` —
Python method-name typos are a confirmed bug class in this codebase
(several fixed already, see `README.md`'s bug-hunt history) — grep for
the method being called and verify it actually exists before assuming
the bug is elsewhere.

## §8 SSL certificate status

> **`ibsng-ops.sh` → option 7.** Auto-detects which domain lives on
> this host instead of you having to remember Active vs Passive.

Run on the host, not inside the container — certbot manages certs at
the host level (see `HA.md`'s SSL section for the full design).

```bash
certbot certificates
```

Cross-check what's actually being served (catches a cert that's valid
on disk but not what Apache is actually presenting — e.g. after a
config change that didn't get reloaded):

```bash
# Active:
echo | openssl s_client -connect ibsng.alonet.co:443 -servername ibsng.alonet.co 2>/dev/null \
    | openssl x509 -noout -issuer -dates -subject

# Passive:
echo | openssl s_client -connect ibs.alonet.co:443 -servername ibs.alonet.co 2>/dev/null \
    | openssl x509 -noout -issuer -dates -subject
```

Renewal is automatic (`certbot.timer`, twice daily, both hosts) with a
deploy hook that reloads Apache inside the container — see `HA.md` for
the full explanation. To test the renewal path without actually
renewing anything: `certbot renew --dry-run`.

## §9 Log file locations

> **`ibsng-ops.sh` → option 8.** Submenu covering every row below,
> follow-mode or last-50-lines, no need to remember exact paths.

| What | Where | Notes |
|---|---|---|
| Core daemon — lifecycle + `GeneralException`s | `ibsng:/var/log/IBSng/ibs_debug.log` | Not full tracebacks — see next row |
| Core daemon — full Python tracebacks | `ibsng:/var/log/IBSng/ibs_stdout.log` | Only populated if the daemon was (re)launched via the redirect in §2 step 3 — a launch that wasn't will have nothing here even if it crashed |
| Apache — errors | `ibsng:/var/log/apache2/error.log` | |
| Apache — SSL-specific errors | `ibsng:/var/log/apache2/ssl_error.log` | Only relevant once HTTPS is active (§8) |
| PHP fatals | `ibsng:/var/log/php5/error.log` | `display_errors` is deliberately Off — this file is often the *only* place a PHP fatal shows at all |
| Postgres | `ibsng:/var/log/postgresql/postgresql.log` | |
| Periodic cleanup+backup+sync — detailed | Active host: `/var/log/ibsng-sync.log` | Active only — see `HA.md` |
| Periodic cleanup+backup+sync — cron capture | Active host: `/var/log/ibsng-sync-cron.log` | Should normally just mirror the above |
| Certbot | Both hosts: `/var/log/letsencrypt/letsencrypt.log` | |

`ibsng:/path` means run `docker exec ibsng cat /path` (or `tail`) —
it's inside the container, not on the host.
