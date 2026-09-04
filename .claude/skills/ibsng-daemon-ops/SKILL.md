---
name: ibsng-daemon-ops
description: Use when restarting the IBSng core daemon (ibs.py), debugging a "Can't connect to IBS Core" or HTTP 500 error from the admin panel, or investigating why a page silently fails. Covers the double-fork/PID1 pitfall, the TTY-attachment pitfall, and how to get the real XML-RPC fault string instead of IBSng's generic error page.
---

# IBSng core daemon — restart and debugging

## Restarting the daemon safely

`ibs.py` double-forks (classic Unix daemon pattern): the launcher process
exits(0) once the forked child confirms startup. Two ways this goes
wrong, both previously caused real outages:

1. **Never run it attached to an interactive TTY that will later close**:
   ```bash
   # WRONG — breaks stdout/stderr once this session ends, causing every
   # subsequent HTTP request to the daemon to fail:
   docker exec -it ibsng python2.7 /usr/local/IBSng/ibs.py
   ```
   Always redirect to a file instead:
   ```bash
   docker exec -d ibsng bash -c "python2.7 /usr/local/IBSng/ibs.py >> /var/log/IBSng/ibs_stdout.log 2>&1"
   ```

2. **Never `exec` it as a container's PID 1** (only relevant if editing
   `entrypoint.sh` — this is why the entrypoint runs it as a plain
   foreground command and tails a log file afterward, rather than
   `exec`ing into it directly; PID 1 exiting kills the whole container's
   PID namespace including the daemon child).

### Full safe restart sequence
```bash
# 1. Graceful stop
docker exec ibsng bash -c "kill -TERM \$(cat /var/run/IBSng.pid) 2>/dev/null; sleep 3"

# 2. Verify the port is ACTUALLY free before relaunching — stale/zombie
#    processes have caused "Address already in use" before
docker exec ibsng ss -tlnp | grep 1235
# if still bound, find the real PID and kill -9 it specifically:
docker exec ibsng ps aux | grep python
docker exec ibsng bash -c "kill -9 <real_pid>"

# 3. Relaunch (redirected, detached — see above)
docker exec -d ibsng bash -c "python2.7 /usr/local/IBSng/ibs.py >> /var/log/IBSng/ibs_stdout.log 2>&1"

# 4. Confirm it actually started
sleep 3
docker exec ibsng tail -10 /var/log/IBSng/ibs_debug.log
# look for "IBS successfully started." — if instead you see a Python
# traceback, read it fully before declaring success
```

## Debugging "Can't connect to IBS Core (HTTP/1.0 500 Internal Server Error)"

**This message is IBSng's generic handler for ANY XML-RPC fault**, not
just real connectivity problems (it comes from a hardcoded string in
`interface/xmlrpc/xmlrpc.inc`). Don't assume the daemon is down or
unreachable — get the real fault string first:

```bash
docker exec -i <container> bash -c "cat > /tmp/t.php" <<'EOF'
<?php
require("/usr/local/IBSng/interface/xmlrpc/xmlrpc.inc");
$client = new xmlrpc_client("/", "127.0.0.1", 1235);
$msg = new xmlrpcmsg("<method.name>", array(php_xmlrpc_encode(array(/* params matching what the failing PHP page actually sends */))));
$resp = $client->send($msg, 10);
if (!$resp) echo "NO RESPONSE\n";
elseif ($resp->faultCode()) echo "FAULT: " . $resp->faultString() . "\n";
else { echo "SUCCESS\n"; print_r(php_xmlrpc_decode($resp->value())); }
EOF
docker exec -it <container> php5 /tmp/t.php
```

To find the exact method name and params a failing admin panel page
actually sends, read the PHP source of that page and trace it back
through `interface/IBSng/inc/*.php`'s `Request`-derived classes (each
wraps one `core.<method>` XML-RPC call — check the constructor for the
exact method string and param keys).

Cross-reference the fault string against `core/` — Python method-name
typos are a known bug class in this codebase (see PROJECT_BRIEF.md §5
for a confirmed example: `getUserInfoByNormalUsername` called a
nonexistent `getLoadedUsersByUsername` instead of the real
`getLoadedUsersByNormalUsername`). Grep for the method being called and
verify it actually exists before assuming the bug is elsewhere.

## Common log locations
- `/var/log/IBSng/ibs_debug.log` — lifecycle events + `GeneralException`s
  only (not full Python tracebacks)
- Wherever stdout was redirected on last manual restart (commonly
  `/var/log/IBSng/ibs_stdout.log`) — full tracebacks land here
- `/var/log/apache2/error.log` — PHP fatal errors if `log_errors` is on
  and pointed here, plus generic "HTTP error, got response: ..." lines
  whenever a PHP page's XML-RPC call fails (these don't contain the real
  fault string — use the direct XML-RPC test above for that)
- `/var/log/php_errors.log` (if configured per PROJECT_BRIEF.md) — PHP
  fatals with actual file/line info, since `display_errors` is Off
