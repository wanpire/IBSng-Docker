# AloNet Ghost-Guard (ported from WANPIRE v2, stateless)
#
# A customer's device that reconnects from a new address can leave the old
# ovpn/l2tp/sstp/pptp session up on the router. It passes no traffic, but the
# router keeps sending interim updates, so IBSng counts it online and it
# uses one of the customer's concurrent-login slots. The existing hourly
# Remove-Ghosts scheduler only removes interfaces that are NOT running, so it
# never catches these.
#
# Rule: a session whose own interface has received 0 bytes since connecting
# and that has been up >= minUp is a ghost. A session that ever received a
# byte is never touched, so idle users are safe.
#
# - Session -> interface is matched by the session's unique dynamic
#   /ip address (network = session address), not by interface name: a
#   user's second session is named <ovpn-user-1>, and a name lookup would
#   read the first session's counters. Sessions without exactly one match
#   are skipped and counted as "unmatched".
# - No :global state: WANPIRE's v1 kept state in a :global that did not
#   survive between scheduled runs and so never flagged anything.
# - The per-session body is wrapped in :do/on-error so a session that
#   disconnects mid-run does not abort the run.
# - Hits go to :log error (some routers only log that topic); a one-line
#   summary goes into the Ghost-Guard scheduler's comment.
#
# Keep dryRun true until the dry-run hits have been checked against the
# router's counters and IBSng. Install: see mikrotik-ghost-guard-install.rsc.
:local dryRun true
:local minUp 15m
:local nAll 0
:local nZero 0
:local nHit 0
:local nMiss 0
:foreach a in=[/ppp active find where service~"^(ovpn|l2tp|sstp|pptp)\$"] do={
    :set nAll ($nAll + 1)
    :do {
        :local nm [/ppp active get $a name]
        :local svc [/ppp active get $a service]
        :local up [/ppp active get $a uptime]
        :local ias [/ip address find where dynamic and network=[/ppp active get $a address]]
        :if ([:len $ias] = 1) do={
            :if ([/interface get [/ip address get ($ias->0) interface] rx-byte] = 0) do={
                :set nZero ($nZero + 1)
                :if ($up >= $minUp) do={
                    :set nHit ($nHit + 1)
                    :local who ($svc . " " . $nm . " from " . [/ppp active get $a caller-id] . ", up " . $up)
                    :if ($dryRun) do={
                        :log error ("ghost-guard DRY-RUN: would remove " . $who . ", 0 bytes received")
                    } else={
                        /ppp active remove $a
                        :log error ("ghost-guard: removed " . $who . ", 0 bytes received")
                    }
                }
            }
        } else={
            :set nMiss ($nMiss + 1)
        }
    } on-error={ :set nMiss ($nMiss + 1) }
}
:local mode ""
:if ($dryRun) do={ :set mode " (dry-run)" }
/system scheduler set [find name="Ghost-Guard"] comment=("ghost-guard last run: checked " . $nAll . " ppp sessions, " . $nZero . " with 0 bytes received, " . $nHit . " ghost(s), " . $nMiss . " unmatched" . $mode)
