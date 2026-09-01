# IBSng in Docker — built from source (working, PHP 5.6 base)

Built and debugged end-to-end on a live Ubuntu 24 server. This is the
**final, consolidated** version after a long debugging pass — see
"Why PHP 5.6" below for why the base image looks the way it does.

## Usage

```bash
sudo bash ibsng-manager.sh
```
Choose **1) Install**. Default ports: web 80, API 1235, RADIUS 1812/1813 udp.

- Web panel: `http://<server-ip>/IBSng/admin` (login: `system` / your password)
- API (XML-RPC): port 1235
- RADIUS: 1812/udp (auth), 1813/udp (accounting)

## Why PHP 5.6 (Debian jessie), not a modern PHP

IBSng (2010) was written for PHP 5. An earlier version of this package
ran on Debian buster (PHP 7.3) and required patching around a long tail
of PHP7 breaking changes one at a time: the `Error` and `Generator`
reserved class names, removed functions (`ereg`, `split`, `dl`), the
removed `&new` reference-assignment syntax, and more. Each fix
uncovered the next, with no guarantee more wouldn't be waiting
(reports, graphs, VoIP modules, etc. were never fully exercised).

For a server meant to carry real paying users, this is not sustainable network for
IBSng — we can't work — so this version runs everything on Debian
**jessie** with **PHP 5.6 native**, the environment IBSng actually
targets. Only the fixes below remain necessary.

## Patches actually needed on PHP 5.6

1. **PyGreSQL 7-arg `connect()` shim** — IBSng calls the classic
   PyGreSQL API with 7 positional args (`dbname, host, port, opt, tty,
   user, password`); some PyGreSQL builds only accept 6. The shim in
   the Dockerfile tries the real call first and only trims the unused
   `tty` slot on a genuine `TypeError`, so it's a no-op if the bundled
   PyGreSQL already accepts 7 args.
2. **`class Generator` rename** — PHP 5.5+ ships its own `final class
   Generator` (for `yield`); IBSng's own `Generator` class in
   `interface/IBSng/inc/generator/generator.php` collides with it and
   is renamed to `IBSngGenerator` across the interface.
3. **`templates_c` ownership** — Smarty (IBSng's template engine)
   silently renders a blank page (HTTP 200, zero bytes, **no error
   logged anywhere**) if it can't write its compiled-template cache.
   `templates_c` must be owned by `www-data` — this caused "some pages
   work, some are just blank" and is the single easiest thing to miss.
4. **IBSng core daemon PID 1 handling** — `ibs.py` double-forks (classic
   Unix daemon pattern: parent exits once the child confirms startup).
   If run as the container's PID 1 directly, the parent's exit kills
   the whole container (PID 1 death kills every process in a PID
   namespace). `entrypoint.sh` runs it as a normal foreground command
   instead, so bash (the real PID 1) survives and adopts the orphaned
   daemon child, then tails IBSng's log file forever to keep the
   container alive.
5. **jessie-slim's stripped `/usr/share/man`** — `postgresql-client`'s
   postinst script assumes `/usr/share/man/man1` etc. exist (to symlink
   man pages) and fails otherwise on the `slim` base; recreated before
   installing packages.
6. **Debian's Postgres cluster wrapper bypass** — the entrypoint runs
   Postgres directly via `pg_ctl` against a data dir we `initdb`
   ourselves, rather than `service postgresql start` / the
   `pg_createcluster` machinery, which doesn't know about a
   hand-initialized data directory.

None of the PHP7-era patches (`ereg`, `split`, `&new`, `class Error`)
are needed on this base — they were purely PHP7 breaking changes.

## If SourceForge's download link changes

```bash
docker build --build-arg IBSNG_URL=<direct .tar.bz2 link> -t ibsng-local:latest .
```

## Data persistence

Postgres data lives in the `ibsng_pgdata` Docker volume. `Delete` (menu
option 6 in the manager script) removes the container but keeps this
volume. `Update` (option 5) rebuilds the image without touching it.

## Before going live: test checklist

- Login/logout, a second restricted admin account, permission enforcement
- Add New Users (single + bulk), Search User, edit user (credit/expiry/group), lock/unlock, kill session, delete
- Groups: create/edit/delete; Charges: create/edit/delete (internet + VoIP if used)
- IP Pool: create pool, add/remove IPs, assign to group
- Reports (connection logs, CSV export) and graphs (realtime/onlines)
- RADIUS auth against a real test user:
  ```bash
  apt-get install -y freeradius-utils
  echo "User-Name=<test-user>,User-Password=<test-pass>" | radclient -x 127.0.0.1:1812 auth testing123
  ```
  Expect `Access-Accept`.
- API reachability for the Telegram bot: `docker exec -it ibsng wget -S -O - http://127.0.0.1:1235/`
- `docker restart ibsng` and, separately, a full host reboot — confirm IBSng comes back up on its own both times.
