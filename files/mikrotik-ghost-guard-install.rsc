# AloNet Ghost-Guard installer: paste into a MikroTik terminal as an ADMIN
# user (not ibs). Installs in DRY-RUN: it only logs "would remove" and never
# disconnects anyone. Body = files/mikrotik-ghost-guard.rsc (keep in sync).
# Do NOT feed this through `ssh user@router "<script>"`: SSH exec runs each
# line on its own, which breaks the :if/:do blocks apart.
#
# Check after install:
#   /system scheduler print detail where name=Ghost-Guard   (comment = last run summary)
#   /log print where message~"ghost-guard"
# Go live (only after dry-run hits were verified):
#   edit the ghost-guard script (Winbox/WebFig: System > Scripts) and change
#   its first line to ":local dryRun false".
# Remove:
#   /system scheduler remove [find name=Ghost-Guard]; /system script remove [find name=ghost-guard]
/system script add name=ghost-guard policy=read,write,test comment="AloNet Ghost-Guard v2 (IBSng-Docker files/mikrotik-ghost-guard.rsc)" source={
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
}
/system scheduler add name=Ghost-Guard interval=15m start-time=startup policy=read,write,test on-event="/system script run ghost-guard" comment="ghost-guard: not run yet"
/system script run ghost-guard
/system scheduler print detail where name=Ghost-Guard
