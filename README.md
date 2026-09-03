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

## Systematic bug-hunt pass (upstream IBSng bugs, unrelated to Docker/PHP5.6)

A full pass was made over IBSng's own source (not just the pages hit
during manual click-through testing) looking for the specific class of
bug that caused the "search user by username" failure: a method call
whose name doesn't match any real method definition anywhere in the
codebase — a typo or a refactor that didn't update every call site.
These are genuine upstream bugs in IBSng's 2010 source, not something
introduced by this packaging.

**Fixed** (all applied as `sed`/`printf` patches in the Dockerfile,
right after the source is fetched):

1. **`core/user/user_actions.py`** — `getUserInfoByNormalUsername()`
   called `self.getLoadedUsersByUsername()`, which doesn't exist;
   the real method (defined a few lines above, same class) is
   `getLoadedUsersByNormalUsername()`. **Correction / honesty check:**
   in the SourceForge "latest" snapshot this Dockerfile currently pulls,
   this exact method is not wired up to any XML-RPC handler
   (`core/user/user_handler.py`'s `UserHandler` only exposes
   `getUserInfo`/`searchUser`/etc, both of which already call the
   correctly-spelled method directly) — so it's dead code here, not
   the live cause of a username-search failure on this snapshot
   (confirmed: searching by username through the actual admin panel
   works correctly, see the testing notes below). Fixed anyway since
   it's a genuine bug that would throw `AttributeError` the instant
   anything does call it — directly, or in a different IBSng build.
   **On the XML-RPC error-handling mechanism in general** (relevant to
   the debugging tips below): `core/server/handlers_manager.py`'s
   `dispatch()` wraps every handler call in its own broad
   `except Exception` and converts it into a real `XMLRPCFault` with a
   readable message — verified directly (a deliberately malformed
   method name came back as a proper `FAULT: parseMethodName: invalid
   method_name --...--` string, not a bare 500). So a bug *inside* a
   handler method generally does **not** produce the generic "Can't
   connect to IBS Core" symptom; see item 5 below (a failure during
   *response serialization*, outside that try/except) for what does.
2. **`core/db/ibs_db.py`** — a result-formatting helper called
   `self.getDictWrapperResult()`, which doesn't exist; the real method
   is `getDicWrapperResult()` (missing a "t" in "Dict"). **Currently
   dead code**: it's only reached via `selectQuery(query, result_type=2)`,
   and nothing in `core/` ever calls `selectQuery` with `result_type=2`
   — but it would throw `AttributeError` the moment anything did, so
   fixed pre-emptively rather than left as a landmine.
3. **`core/ras/rases/portmaster.py`** — `self.__getPortFromOid()` (three
   call sites), which doesn't exist; the real method is
   `__getPortFromOID()` — case mismatch only. **This one is live**: it
   sits on the periodic online-user/traffic-polling path
   (`UpdateUsersRas.updateUserList()` / `updateInOutBytes()` in
   `core/ras/ras.py`, driven by the core daemon's periodic-event
   scheduler) for any RAS configured with type "PortMaster". The
   exception is caught and logged by `core/event/periodic_events.py`
   rather than crashing the daemon, so the failure is silent from the
   admin panel's point of view: a PortMaster RAS simply never tracks
   online users or in/out byte counters, while flooding the core
   daemon's log with `AttributeError`s every polling cycle. If you use
   RAS type "PortMaster", verify this is actually fixed in your build
   before relying on its online/traffic stats.
4. **`interface/IBSng/admin/plugins/edit_funcs.php`** — missing
   `require_once`. **Found only by actually completing "Add New User" in
   a browser against a freshly built image** — no amount of grepping for
   misspelled names catches this class of bug, since the function names
   are spelled correctly; the file that calls them just never pulls in
   the file that defines them. `editUserAssignValues()` calls
   `intSetSingleUserInfo()`, `intShowSingleUserInfoInput()`, and
   `intSetSingleUserGroupAttrs()`, all three defined in
   `admin/user/user_info_funcs.php` — which `edit_funcs.php` never
   requires. It happens to work when reached from a page that already
   pulled in `user_info_funcs.php` first, but `edit_funcs.php`'s other
   two real callers — `add_new_users.php`'s post-create redirect to
   `plugins/edit.php`, and `search_user_edit.php`'s single-user Edit
   action — don't. **Symptom:** adding a single user (count=1) hits a
   hard fatal error, `Call to undefined function
   intShowSingleUserInfoInput()`, immediately after the user is created
   — i.e. **the primary "Add New User" flow was completely broken**.
   Fixed by adding the require, matching the existing cross-directory
   require convention already used elsewhere in `admin/` (relative to
   the including file's own directory).
5. **`core/server/xmlrpcserver.py`** — Python 2's stdlib `xmlrpclib` has
   no marshaller for `decimal.Decimal`, and PyGreSQL returns Postgres
   `NUMERIC`/`DECIMAL` columns (`credit`, charges — any money field,
   which is most of what a billing system's API returns) as `Decimal`.
   The instant a response contains one anywhere in its structure,
   `do_POST`'s `xmlrpclib.dumps(response, methodresponse=1)` raises
   `TypeError: cannot marshal <class 'decimal.Decimal'> objects`. This
   happens *after* the handler already ran successfully and *outside*
   the try/except that converts real handler errors into a proper
   fault (see the note on item 1 above) — verified by triggering it and
   reading the traceback out of `/var/log/IBSng/ibs_error.log`, a log
   file this README's debugging notes hadn't previously mentioned (see
   below). It falls straight into `do_POST`'s outermost bare `except:`
   and returns a bare HTTP 500 with an empty body — from the PHP side,
   indistinguishable from the "Can't connect to IBS Core" symptom.
   **Symptom:** viewing a newly-created user's info (which is exactly
   what "Add New User" does right after creating one) reliably 500s,
   because a fresh user always has a `credit` value, even `0`. This is
   almost certainly the single biggest cause of "the admin panel is
   randomly broken"-type reports on any real deployment, since it can
   trigger on nearly any endpoint that returns money fields (user info,
   credit change, reports with sums — all independently confirmed
   working after the fix, including a `SUM()`-aggregated report total).
   Fixed the same way the PyGreSQL shim above is fixed: register a
   marshaller for `decimal.Decimal` (convert to `float`, then reuse
   `xmlrpclib`'s own `dump_double`) in `core/server/xmlrpcserver.py`,
   the module that owns response serialization, so it runs once at
   daemon startup and covers every response for the life of the
   process.
6. **`interface/IBSng/inc/error.php`** — loaded on every single
   admin-panel request, it unconditionally ran `ini_set("display_errors",
   1)`, silently overriding whatever `php.ini` says on every request —
   so the `display_errors = Off` set in the Dockerfile (see below) was
   never actually in effect. Caught by hitting a page that triggers a
   PHP notice (the pre-existing, deliberately-left-alone `=& new`
   deprecated-syntax line noted below) and watching it get rendered
   straight into the live admin UI despite `display_errors` supposedly
   being off. Fixed by removing the `ini_set` call so `php.ini`'s value
   actually governs it. While in that file: `errorHandler()`'s "don't
   log deprecated warnings" check compared `$errno!=2048`, but `2048` is
   `E_STRICT`, not `E_DEPRECATED` (`8192`) — the comment
   (`//deprecated warnings`) makes the intent obvious, so corrected the
   constant too. Both are genuine bugs in IBSng's own error-handling
   bootstrap, not something introduced by this Docker packaging.

**A new log file worth knowing about:** `core/ibs_exceptions.py`
routes `logException(LOG_ERROR, ...)` to `/var/log/IBSng/ibs_error.log`
— separate from `ibs_debug.log` (which only captures `GeneralException`s
and lifecycle events) and from the container's own stdout (which only
carries whatever the pre-fork launcher printed before daemonizing, plus
anything a worker thread happens to `print`). Full Python tracebacks for
exceptions raised inside a request-handling thread — including the
`TypeError` above — land in `ibs_error.log`. There are also
`ibs_radius.log`, `ibs_server.log`, `ibs_queries.log`, and
`ibs_console.log` alongside it; none of these were mentioned in the
original debugging notes.

**Investigated, found to be pre-existing incomplete code, deliberately
NOT touched:** `core/ras/ras_actions.py`'s `deleteRas()` (and its
helper `__deleteRasDB()`) call `self.__deleteRasLogicallyDB()` /
`self.__deleteRasLogicallyQuery()`, neither of which is defined
anywhere. Unlike the three bugs above, this isn't a typo with an
obvious correct name sitting nearby — it looks like a "soft delete"
variant that was planned (sibling methods `__deleteRasDB`/
`__deleteRasQuery`/`__deleteRasAttrsQuery` exist and follow a clear
naming pattern the "Logically" versions never got) but never
implemented. `deleteRas()` is explicitly commented `UNUSED FOR NOW!
... we don't need it because we should active/deactive it [a RAS]
instead`, and is never called from anywhere in `core/` or `interface/`
— confirmed dead. Left as-is rather than guessing at an implementation;
worth knowing about if a future feature ever tries to wire RAS deletion
up to that code path.

**Checked and found NOT to be a problem on this PHP 5.6 base** (so
don't waste time re-investigating these if they come up again):

- `ereg()`/`eregi()`/`split()` — used in a handful of IBSng's own files
  (`interface/IBSng/inc/errors.php`, `search_user_report_creator.php`,
  `connection_logs_report_creator.php`, `generator_controller.php`,
  `referrer.php`, `web_analyzer_logs_report_generator_controller.php`).
  These were deprecated in PHP 5.3 but only *removed* in PHP 7.0 — on
  PHP 5.6 they still work (just emit `E_DEPRECATED`, which isn't fatal
  and isn't normally displayed). Notably `errors.php` — the class that
  parses every error string the admin panel displays — uses `split()`
  internally; this is fine on 5.6, but would itself become a second,
  error-message-swallowing bug if this project were ever ported to a
  newer PHP without re-checking it.
- `each()` / `create_function()` — only found inside vendored
  third-party libraries (`jpgraph`, `smarty`), never in IBSng's own
  code; also both just deprecated, not removed, until PHP 7.2/8.0.
- The old `=& new Foo()` reference-assignment syntax — one occurrence,
  in `interface/IBSng/inc/generator/report_generator/csv_report_generator.php`.
  Deprecated-but-functional on PHP 5.x (fatal parse error only on PHP
  7+), so left alone.
- Own-class-name collisions with PHP reserved/built-in names: only two
  exist in the whole `interface/` tree — `Generator` (already fixed,
  see above) and `Error`. `Error` as a built-in class/interface didn't
  exist before PHP 7.0, so IBSng's own `class Error` in
  `interface/IBSng/inc/errors.php` is not a collision at all on PHP
  5.6 — no action needed.
- A full `$this->`/`self::`/`parent::` method-call cross-reference
  across all of `interface/IBSng/inc/**/*.php` and
  `interface/IBSng/admin/**/*.php` (184 files, ~360 call sites) found
  no other instances of the "calls a method that doesn't exist"
  pattern in the PHP admin panel — that bug class was isolated to the
  three Python-side instances documented above.
- `log_errors`/`display_errors`/`error_log` in `/etc/php5/apache2/php.ini`
  are now set explicitly by the Dockerfile (`log_errors = On`,
  `display_errors = Off`, `error_log = /var/log/php5/error.log`,
  directory pre-created and owned by `www-data`) rather than relying on
  Debian's packaged default — since both of IBSng's own error-hiding
  behaviors (the XML-RPC generic-500 issue above, and Smarty's silent
  blank page) mean this log file is often the only place a real fatal
  ever surfaces.

## Building this repo on Windows

`.gitattributes` forces LF line endings on every tracked file
regardless of a contributor's local `core.autocrlf`. `files/entrypoint.sh`
and `files/setup.exp` get `COPY`'d straight into the Linux image and run
via their `#!/bin/bash` / `#!/usr/bin/expect` shebang; a Windows checkout
with `core.autocrlf=true` silently rewrites them to CRLF, which breaks
the shebang and fails as `exec /entrypoint.sh: no such file or
directory` with no other clue. Discovered while build-testing this repo
on Windows. If you already had a checkout from before `.gitattributes`
was added, force it to re-normalize: `git add --renormalize .`, then
(since that alone only fixes the index, not files already on disk)
delete and re-checkout the affected files, or just re-clone.

## If SourceForge's download link changes

```bash
docker build --build-arg IBSNG_URL=<direct .tar.bz2 link> -t ibsng-local:latest .
```

## Data persistence

Postgres data lives in the `ibsng_pgdata` Docker volume. `Delete` (menu
option 6 in the manager script) removes the container but keeps this
volume. `Update` (option 5) rebuilds the image without touching it.

## Before going live: test checklist

Items marked ✅ were verified locally (Docker Desktop, this build) as
part of the bug-hunt pass above — login, create group, Add New User
(single, with an Internet username/password), Search User by username,
Change Credit, and the Credit Change report with `SUM()` totals all
confirmed working end to end. Everything else still needs exercising —
ideally against the real target server, since some of it (RADIUS,
restart/reboot resilience) can't be meaningfully tested any other way.

- ✅ Login/logout — ⬜ a second restricted admin account, permission enforcement
- ✅ Add New Users (single) — ⬜ bulk — ✅ Search User — ⬜ edit user (expiry/group) — ✅ edit user (credit) — ⬜ lock/unlock, kill session, delete
- ✅ Groups: create — ⬜ edit/delete; Charges: create/edit/delete (internet + VoIP if used)
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
