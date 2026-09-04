# IBSng Docker — Project Memory

Read PROJECT_BRIEF.md for full background. This file is just fast-recall
facts so you don't have to re-derive them each session.

## Servers
- **Active** (live, do not disrupt): `root@172.17.3.200` / `ibsng.alonet.co`
  - Container name: `ibsng` (this repo's image, `ibsng-local:latest`)
  - DB volume: `ibsng_pgdata`
- **Passive** (status changes over the course of this project — check
  current state with `docker ps -a` before assuming, don't trust stale
  memory): `root@172.17.2.200`
  - As of the last session: still running the old closed-source
    `boroumandhosein/ibsng-irsupp` image, container name `ibsng`, holding
    the authoritative live data pending migration to Active.
- SSH: `ssh -i ~/.ssh/ibsng_deploy root@<ip>` (passwordless, already installed)
- A second dedicated key `~/.ssh/ibsng_ha_sync` may exist for Active↔Passive
  sync scripts specifically — check before creating a new one.

## Container internals (both servers, once both run this repo's image)
- DB: PostgreSQL, user `ibs` / password `ibsdbpass`, database `IBSng`,
  local unix socket only (`DB_HOST=None` in `core/db_conf.py`)
- Core daemon: `/usr/local/IBSng/ibs.py`, PID file `/var/run/IBSng.pid`,
  responds to `SIGTERM` for graceful shutdown
- Admin panel: `http://<ip>/IBSng/admin`, login `system` / (set at install)
- XML-RPC API: port 1235 tcp — RADIUS: 1812/1813 udp
- PHP error log: `/var/log/php_errors.log` (log_errors On, display_errors Off)
- Core daemon log: `/var/log/IBSng/ibs_debug.log` (lifecycle events +
  `GeneralException`s only, not full tracebacks — full tracebacks only
  appear in wherever stdout was redirected on manual restart)

## Non-negotiable operational rules (see destructive-confirm skill for the full policy)
1. Never `docker exec -it ... python2.7 ibs.py` and then close the
   terminal — this breaks the daemon's stdout/stderr and causes every
   subsequent request to fail with a misleading 500 error. Always use
   `docker exec -d ibsng bash -c "python2.7 /usr/local/IBSng/ibs.py >> /var/log/IBSng/ibs_stdout.log 2>&1"`.
2. Before restarting the daemon, verify port 1235 is actually free
   (`ss -tlnp | grep 1235`) — stale/zombie processes have caused
   "Address already in use" before. Find and kill the real PID, don't
   just `pkill` and assume it worked.
3. Any `dropdb`, `TRUNCATE`, or destructive restore on either server's
   database requires explicit human confirmation immediately before
   that specific command — see the destructive-confirm skill.
4. IBSng's own error handling shows a generic "Can't connect to IBS
   Core" for almost any XML-RPC fault, not just real connectivity
   issues — don't chase network theories first; get the real fault
   string via a direct XML-RPC test call (see ibsng-daemon-ops skill).

## Repo
https://github.com/wanpire/IBSng-Docker — `Dockerfile`, `files/entrypoint.sh`,
`ibsng-manager.sh`. Rebuild after source changes:
`docker build --no-cache -t ibsng-local:latest .`
